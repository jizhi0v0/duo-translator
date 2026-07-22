import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var statusItem: StatusItemController!
    private var hotkeys: HotkeyManager!
    private var editKeyMonitor: Any?
    /// True while a `KeyboardShortcuts.Recorder` is capturing a shortcut. The
    /// edit-key monitor below must stand down during that window, or it swallows
    /// the very keystrokes the recorder is trying to capture — ⌘C/⌘V/⌘X/⌘A/⌘Z
    /// and ⇧⌘Z could never be assigned as shortcuts, and the interception races
    /// other combos too.
    private var recorderActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads settings: a UI-test run must not inherit — or
        // leave behind — real preferences. A test that resizes a card would
        // otherwise persist that height into the user's own defaults and every
        // later run (test or not) would start from it.
        if ProcessInfo.processInfo.arguments.contains("-uiTest") {
            SettingsStore.resetForUITests()
        }

        // LSUIElement apps have no visible menu bar, but a main menu must still
        // exist for ⌘C/⌘V/⌘A/⌘Z key equivalents to reach text fields.
        NSApp.mainMenu = Self.buildMainMenu()

        // While a shortcut recorder is active, let every keystroke through so it
        // can be captured; KeyboardShortcuts posts this when recording starts and
        // stops.
        // `queue: nil` so the flag flips synchronously on the thread that posts
        // the notification (the main thread, inside the recorder's
        // become/resign-first-responder). With `.main` the block is enqueued for
        // the next run-loop turn, leaving a gap where recording has started but
        // the monitor still intercepts — which ate the first keystrokes and made
        // recording feel flaky.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"),
            object: nil, queue: nil
        ) { [weak self] note in
            let active = (note.userInfo?["isActive"] as? Bool) ?? false
            if Thread.isMainThread {
                self?.recorderActive = active
            } else {
                DispatchQueue.main.async { self?.recorderActive = active }
            }
        }

        // Belt and suspenders: menu key-equivalent routing for accessory apps
        // has been flaky across macOS versions, so intercept the standard edit
        // shortcuts ourselves and dispatch straight to the first responder.
        editKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.recorderActive == true { return event }
            return Self.handleEditKeyEquivalent(event) ? nil : event
        }

        coordinator = AppCoordinator()
        statusItem = StatusItemController(coordinator: coordinator)
        hotkeys = HotkeyManager(coordinator: coordinator)

        KeychainStore.shared.preferSynchronizable = CloudSync.hasKeychainGroupsEntitlement
        CloudSync.shared.start(settings: .shared)

        installDebugHooks()

        // UI tests launch with `-uiTest` and seed the panel deterministically via
        // the `UITEST_INPUT` environment variable (no hotkeys / typing needed).
        if ProcessInfo.processInfo.arguments.contains("-uiTest") {
            let env = ProcessInfo.processInfo.environment
            let seed = env["UITEST_INPUT"] ?? ""
            let resultCount = Int(env["UITEST_RESULTS"] ?? "") ?? 0
            let streaming = env["UITEST_STREAMING"] == "1"
            // Remembered-position seed ("x,topY", Cocoa coords) for the restore
            // test — written to the screen the panel is about to open on, since
            // dragging needs event posting the test runner may not be allowed.
            if let raw = env["UITEST_PANEL_TOPLEFT"] {
                let parts = raw.split(separator: ",").compactMap { Double($0) }
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                    ?? NSScreen.main
                if parts.count == 2, let screen {
                    SettingsStore.shared.setPanelTopLeft(
                        NSPoint(x: parts[0], y: parts[1]),
                        forScreen: PanelController.screenKey(for: screen)
                    )
                }
            }
            coordinator.uiTestShowPanel(
                seed: seed,
                resultCount: resultCount,
                streaming: streaming,
                resultText: env["UITEST_RESULT_TEXT"]
            )
        } else {
            // Warm the panel off-screen once launch settles, so the first 划词
            // skips the lazy build + first-layout stall. Deferred so it never
            // competes with launch or hotkey registration.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak coordinator] in
                coordinator?.prewarmPanel()
            }
        }
    }

    /// Local-only diagnostics, driven via `notifyutil`-style distributed
    /// notifications so paste/focus issues can be debugged over SSH.
    private func installDebugHooks() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.openSettings"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.openSettings()
            }
        }
        // Drive a real streaming translation without hotkeys (panel debug):
        // object carries the source text, or empty for a built-in sample.
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.translate"),
            object: nil, queue: .main
        ) { [weak self] note in
            let text = (note.object as? String).flatMap { $0.isEmpty ? nil : $0 }
            Task { @MainActor in
                self?.coordinator.translateText(text ?? Self.debugSampleText)
            }
        }
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.pageMode"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.debugTogglePageMode()
            }
        }
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.pin"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.debugTogglePin()
            }
        }
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.close"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.debugClosePanel()
            }
        }
        // Park the panel at a named vertical spot ("bottom" / "top" / "mid")
        // for layout verification — the LSUIElement panel can't be dragged by
        // synthetic mouse events.
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.movePanel"),
            object: nil, queue: .main
        ) { [weak self] note in
            let spec = (note.object as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "bottom"
            Task { @MainActor in
                self?.coordinator.debugMovePanel(spec)
            }
        }
        // Run an LLM vision OCR pass on a synthetic sample image (object =
        // optional model override, e.g. "gpt-4o"); result/error goes to the log.
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.ocrTest"),
            object: nil, queue: .main
        ) { [weak self] note in
            let model = (note.object as? String).flatMap { $0.isEmpty ? nil : $0 }
            Task { @MainActor in
                await self?.coordinator.debugOCRTest(model: model)
            }
        }
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.dumpState"),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let keyWindow = NSApp.keyWindow
                let responder = keyWindow?.firstResponder
                Log.app.error("""
                debugState active=\(NSApp.isActive) \
                keyWindow=\(keyWindow?.title ?? "nil", privacy: .public) \
                firstResponder=\(responder.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public)
                """)
            }
        }
    }

    /// Multi-paragraph sample for `debug.translate`, long enough that the
    /// streamed result exercises the card viewports and page mode.
    private static let debugSampleText = """
    Tailscale is a mesh VPN built on WireGuard. Instead of routing all traffic \
    through a central server, every node talks directly to every other node \
    whenever possible, falling back to relays only when NAT traversal fails.

    The control plane distributes keys and access policies, while the data \
    plane stays peer-to-peer. This separation is what lets the network scale \
    without the operator ever seeing your traffic.

    In practice, the hardest part is NAT traversal. Home routers, carrier-grade \
    NAT, and corporate firewalls all mangle connections differently, so the \
    client runs a battery of probes to discover the cheapest working path.

    When a direct path exists, latency is close to a plain WireGuard tunnel. \
    When it does not, the DERP relay fleet carries encrypted packets, and the \
    client keeps probing in the background, upgrading to a direct connection \
    the moment one becomes available.
    """

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Returns true when the event was consumed (action found a responder).
    private static func handleEditKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }

        let action: Selector?
        switch (key, flags) {
        case ("v", [.command]): action = #selector(NSText.paste(_:))
        case ("c", [.command]): action = #selector(NSText.copy(_:))
        case ("x", [.command]): action = #selector(NSText.cut(_:))
        case ("a", [.command]): action = #selector(NSText.selectAll(_:))
        case ("z", [.command]): action = Selector(("undo:"))
        case ("z", [.command, .shift]): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action else { return false }

        let responder = NSApp.keyWindow?.firstResponder
        let handled = NSApp.sendAction(action, to: nil, from: nil)
        Log.app.error("""
        editKey \(key, privacy: .public) action=\(action.description, privacy: .public) \
        handled=\(handled) keyWindow=\(NSApp.keyWindow?.title ?? "nil", privacy: .public) \
        firstResponder=\(responder.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public)
        """)
        if handled { return true }

        // macOS 26: SwiftUI text fields hosted in a plain NSHostingView don't
        // resolve `paste:` through the responder chain. Insert the pasteboard
        // text straight into the focused text-input client instead.
        if action == #selector(NSText.paste(_:)),
           let client = responder as? NSTextInputClient,
           let text = NSPasteboard.general.string(forType: .string) {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            Log.app.info("editKey paste via NSTextInputClient fallback")
            return true
        }
        return false
    }

    private static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "退出 DuoTranslator",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }
}

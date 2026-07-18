import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var statusItem: StatusItemController!
    private var hotkeys: HotkeyManager!
    private var editKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps have no visible menu bar, but a main menu must still
        // exist for ⌘C/⌘V/⌘A/⌘Z key equivalents to reach text fields.
        NSApp.mainMenu = Self.buildMainMenu()

        // Belt and suspenders: menu key-equivalent routing for accessory apps
        // has been flaky across macOS versions, so intercept the standard edit
        // shortcuts ourselves and dispatch straight to the first responder.
        editKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleEditKeyEquivalent(event) ? nil : event
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
            coordinator.uiTestShowPanel(seed: seed, resultCount: resultCount)
        }
    }

    /// Local-only diagnostics, driven via `notifyutil`-style distributed
    /// notifications so paste/focus issues can be debugged over SSH.
    private func installDebugHooks() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("dev.bobby.duo.debug.openSettings"),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.coordinator.openSettings()
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

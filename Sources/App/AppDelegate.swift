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
        return NSApp.sendAction(action, to: nil, from: nil)
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

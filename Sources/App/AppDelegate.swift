import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var statusItem: StatusItemController!
    private var hotkeys: HotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps have no visible menu bar, but a main menu must still
        // exist for ⌘C/⌘V/⌘A/⌘Z key equivalents to reach text fields.
        NSApp.mainMenu = Self.buildMainMenu()

        coordinator = AppCoordinator()
        statusItem = StatusItemController(coordinator: coordinator)
        hotkeys = HotkeyManager(coordinator: coordinator)

        KeychainStore.shared.preferSynchronizable = CloudSync.hasKeychainGroupsEntitlement
        CloudSync.shared.start(settings: .shared)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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

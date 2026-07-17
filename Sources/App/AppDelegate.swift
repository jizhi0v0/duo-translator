import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var statusItem: StatusItemController!
    private var hotkeys: HotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        statusItem = StatusItemController(coordinator: coordinator)
        hotkeys = HotkeyManager(coordinator: coordinator)

        KeychainStore.shared.preferSynchronizable = CloudSync.hasKeychainGroupsEntitlement
        CloudSync.shared.start(settings: .shared)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

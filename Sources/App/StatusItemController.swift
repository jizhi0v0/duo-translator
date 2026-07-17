import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "character.bubble",
                accessibilityDescription: "DuoTranslator"
            )
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(makeItem("输入翻译", #selector(openInputWindow), keyEquivalent: ""))
        menu.addItem(makeItem("划词翻译", #selector(translateSelection), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("截图翻译", #selector(ocrTranslate), keyEquivalent: ""))
        menu.addItem(makeItem("截图取字", #selector(ocrToInput), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("统计…", #selector(openStats), keyEquivalent: ""))
        menu.addItem(makeItem("设置…", #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("退出 DuoTranslator", #selector(quit), keyEquivalent: "q"))

        return menu
    }

    private func makeItem(_ title: String, _ action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func openInputWindow() { coordinator.openInputWindow() }
    @objc private func translateSelection() { coordinator.translateSelection() }
    @objc private func ocrTranslate() { coordinator.ocrTranslate() }
    @objc private func ocrToInput() { coordinator.ocrToInput() }
    @objc private func openStats() { coordinator.openStats() }
    @objc private func openSettings() { coordinator.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

import AppKit
import SwiftUI

/// Self-managed settings window. We avoid the SwiftUI `Settings` scene because
/// with `LSUIElement` the private `showSettingsWindow:` action is unreliable;
/// owning the window keeps behavior predictable.
///
/// Panes are hosted in an `NSTabViewController` with `.toolbar` style, which
/// gives the native System-Settings-like toolbar tabs and animated window
/// resizing between panes.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Updates the window title to the selected pane, System-Settings style.
    private final class SettingsTabViewController: NSTabViewController {
        override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            super.tabView(tabView, didSelect: tabViewItem)
            view.window?.title = tabViewItem?.label ?? "设置"
        }
    }

    convenience init() {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar

        let settings = SettingsStore.shared

        func addPane(_ view: some View, label: String, symbol: String, size: NSSize) {
            let host = NSHostingController(
                rootView: AnyView(view.frame(width: size.width, height: size.height))
            )
            host.preferredContentSize = size
            let item = NSTabViewItem(viewController: host)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }

        addPane(GeneralSettingsView(settings: settings),
                label: "通用", symbol: "gearshape", size: NSSize(width: 620, height: 280))
        addPane(EngineListView(settings: settings),
                label: "引擎", symbol: "engine.combustion", size: NSSize(width: 620, height: 460))
        addPane(OCRSettingsView(settings: settings),
                label: "OCR", symbol: "text.viewfinder", size: NSSize(width: 620, height: 400))
        addPane(HotkeySettingsView(),
                label: "快捷键", symbol: "keyboard", size: NSSize(width: 620, height: 280))
        addPane(SyncSettingsView(),
                label: "同步", symbol: "icloud", size: NSSize(width: 620, height: 340))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.title = tabs.tabViewItems.first?.label ?? "设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

import AppKit
import KeyboardShortcuts
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
            addPane(host, label: label, symbol: symbol, size: size)
        }

        func addPane(_ vc: NSViewController, label: String, symbol: String, size: NSSize) {
            vc.preferredContentSize = size
            let item = NSTabViewItem(viewController: vc)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }

        addPane(GeneralSettingsView(settings: settings),
                label: "通用", symbol: "gearshape", size: NSSize(width: 620, height: 280))
        addPane(PermissionSettingsView(),
                label: "权限", symbol: "lock.shield", size: NSSize(width: 620, height: 320))
        addPane(ProviderListView(settings: settings),
                label: "供应商", symbol: "server.rack", size: NSSize(width: 620, height: 460))
        addPane(EngineListView(settings: settings),
                label: "引擎", symbol: "engine.combustion", size: NSSize(width: 620, height: 460))
        addPane(OCRSettingsView(settings: settings),
                label: "OCR", symbol: "text.viewfinder", size: NSSize(width: 620, height: 400))
        // Hotkeys pane is pure AppKit, not a SwiftUI `NSHostingController`.
        // Hosting the `KeyboardShortcuts.Recorder`s in SwiftUI (inside this
        // `NSTabViewController`) left only the first recorder able to become
        // first responder on macOS 26 — the other three couldn't be clicked or
        // Tab-ed into. A native `NSViewController` gives AppKit direct control
        // of the recorders' first-responder / key-view loop.
        addPane(HotkeyPaneViewController(),
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

/// Native hotkeys pane. Uses `ShortcutRecorderView` (a small custom recorder)
/// rather than the library's `NSSearchField`-based one, which misbehaves on
/// macOS 26 — see the note in `ShortcutRecorderView`.
final class HotkeyPaneViewController: NSViewController {
    private static let rows: [(title: String, name: KeyboardShortcuts.Name)] = [
        ("划词翻译", .translateSelection),
        ("输入翻译", .openInputWindow),
        ("截图翻译", .ocrTranslate),
        ("截图取字", .ocrToInput),
    ]

    override func loadView() {
        let root = NSView()

        let header = NSTextField(labelWithString: "全局快捷键")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let grid = NSGridView()
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        for row in Self.rows {
            let label = NSTextField(labelWithString: row.title)
            let siblings = Self.rows.filter { $0.name != row.name }
                .map { (name: $0.name, title: $0.title) }
            grid.addRow(with: [label, ShortcutRecorderView(name: row.name, siblings: siblings)])
        }
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])
        view = root
    }
}

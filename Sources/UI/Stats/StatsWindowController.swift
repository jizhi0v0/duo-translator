import AppKit
import SwiftUI

/// Self-managed stats window, mirroring SettingsWindowController (the SwiftUI
/// Settings scene is unreliable under LSUIElement).
@MainActor
final class StatsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DuoTranslator 统计"
        window.contentView = NSHostingView(rootView: StatsView(store: .shared))
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

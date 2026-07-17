import AppKit
import SwiftUI

final class TranslatorPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Owns the floating translator panel: positioning near the mouse, key-window
/// behavior without activating the app, outside-click dismissal, pinning, and
/// content-driven height growth.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let viewModel = PanelViewModel()

    private var panel: TranslatorPanel!
    private var clickMonitor: Any?
    /// Once the user resizes manually, stop auto-growing until the next run.
    private var userAdjustedHeight = false

    /// Height of everything that isn't the streaming result text.
    private static let chromeHeight: CGFloat = 220
    private static let defaultSize = NSSize(width: 500, height: 360)

    override init() {
        super.init()

        panel = TranslatorPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 280)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }

        let root = PanelRootView(
            viewModel: viewModel,
            run: viewModel.run,
            onContentHeightChange: { [weak self] textHeight in
                self?.growForContent(textHeight: textHeight)
            },
            onClose: { [weak self] in self?.close() }
        )
        panel.contentView = NSHostingView(rootView: root)
    }

    // MARK: - Presentation

    func showInput(prefill: String? = nil, autoTranslate: Bool = false) {
        if let prefill {
            viewModel.inputText = prefill
        }
        userAdjustedHeight = false
        if !panel.isVisible {
            positionNearMouse()
        }
        panel.makeKeyAndOrderFront(nil)
        installClickMonitor()
        viewModel.focusToken += 1
        if autoTranslate {
            viewModel.translate()
        }
    }

    func close() {
        viewModel.run.cancelAll()
        removeClickMonitor()
        panel.orderOut(nil)
    }

    /// Show the panel with a transient notice (capture failures, hints).
    func showNotice(_ message: String) {
        showInput()
        viewModel.notice = message
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var origin = NSPoint(x: mouse.x + 8, y: mouse.y - Self.defaultSize.height - 8)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.defaultSize.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.defaultSize.height - 8)
        panel.setFrame(NSRect(origin: origin, size: Self.defaultSize), display: false)
    }

    private func growForContent(textHeight: CGFloat) {
        guard panel.isVisible, !userAdjustedHeight, !panel.inLiveResize else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }

        let maxHeight = screen.visibleFrame.height * 0.6
        let desired = min(max(Self.chromeHeight + textHeight, Self.defaultSize.height), maxHeight)
        var frame = panel.frame
        let delta = desired - frame.height
        guard abs(delta) > 4 else { return }
        frame.origin.y -= delta
        frame.size.height = desired

        // Keep the panel on screen when growing downward.
        let visible = screen.visibleFrame
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Dismissal

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.viewModel.isPinned else { return }
                self.close()
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        userAdjustedHeight = true
    }

    func windowWillClose(_ notification: Notification) {
        removeClickMonitor()
    }
}

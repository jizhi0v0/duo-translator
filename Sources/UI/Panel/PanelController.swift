import AppKit
import Combine
import SwiftUI

final class TranslatorPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Hosting view that lets the window be dragged from any empty SwiftUI region.
/// Interactive controls (text fields, buttons) return `false` from
/// `mouseDownCanMoveWindow` on their own, so they still receive their clicks;
/// only the empty background hits this view, which reports `true` and hands the
/// drag to AppKit via `isMovableByWindowBackground`.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Owns the floating translator panel: positioning near the mouse, key-window
/// behavior without activating the app, outside-click dismissal, pinning, and
/// content-driven height growth.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let viewModel = PanelViewModel()

    private var panel: TranslatorPanel!
    private var clickMonitor: Any?
    private var runsObserver: AnyCancellable?

    /// Height of everything above the result list (toolbar, input, language bar).
    private static let chromeHeight: CGFloat = 240
    private static let defaultSize = NSSize(width: 500, height: 360)
    /// Hard ceiling for content-driven growth. Beyond this the result area
    /// scrolls instead of the window getting taller (also clamped to the screen).
    private static let maxHeight: CGFloat = 640

    override init() {
        super.init()

        panel = TranslatorPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
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
        // Liquid Glass: the SwiftUI root draws the panel body as glass, so the
        // window itself must be transparent.
        panel.isOpaque = false
        panel.backgroundColor = .clear
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
        panel.contentView = DraggableHostingView(rootView: root)

        // Each translation bumps runGeneration exactly once; reset to the
        // default height then let growForContent expand for the new content,
        // so a short result after a long one snaps back cleanly. Observing
        // runGeneration (not $runs) keeps a single-card retry from snapping
        // the window back mid-session.
        runsObserver = viewModel.run.$runGeneration
            .dropFirst()
            .sink { [weak self] _ in self?.resetToDefaultHeight() }
    }

    // MARK: - Presentation

    func showInput(prefill: String? = nil, autoTranslate: Bool = false) {
        if let prefill {
            viewModel.inputText = prefill
        }
        if !panel.isVisible {
            centerOnActiveScreen()
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

    /// Center the panel on whichever screen the pointer is on (falls back to the
    /// main screen). Growth from `growForContent` expands downward from here.
    private func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = Self.defaultSize
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Grow the panel to fit the stacked result cards, but never past
    /// `maxHeight` (also clamped to the screen). Grow-only: shrinking is
    /// handled once per run by `resetToDefaultHeight`, so the window doesn't
    /// creep down while streaming.
    private func growForContent(textHeight: CGFloat) {
        guard panel.isVisible, !panel.inLiveResize else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }

        let ceiling = min(Self.maxHeight, screen.visibleFrame.height * 0.9)
        let desired = min(max(Self.chromeHeight + textHeight, Self.defaultSize.height), ceiling)
        var frame = panel.frame
        let delta = desired - frame.height
        guard delta > 4 else { return }
        frame.origin.y -= delta
        frame.size.height = desired

        // Keep the panel on screen when growing downward.
        let visible = screen.visibleFrame
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    /// Snap back to the default height with the top edge fixed. Called when a
    /// new translation run begins so content sizes fresh each time.
    private func resetToDefaultHeight() {
        guard panel.isVisible else { return }
        var frame = panel.frame
        let delta = Self.defaultSize.height - frame.height
        guard abs(delta) > 1 else { return }
        frame.origin.y -= delta // keep the top edge in place
        frame.size.height = Self.defaultSize.height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame, frame.maxY > visible.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Dismissal

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.viewModel.isPinned else { return }
                // A click that lands inside the panel's own frame (e.g. a corner
                // or a pass-through region the window didn't opaquely capture)
                // must not dismiss it — only genuine outside clicks close.
                if self.panel.frame.contains(NSEvent.mouseLocation) { return }
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

    func windowWillClose(_ notification: Notification) {
        removeClickMonitor()
    }
}

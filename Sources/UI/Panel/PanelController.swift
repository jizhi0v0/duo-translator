import AppKit
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

    /// Latest measured heights that drive the window fit: the chrome (everything
    /// above the result list) and the result content. Kept so either changing
    /// re-fits against the current value of the other.
    private var chromeHeightMeasured: CGFloat = chromeHeight
    private var resultHeightMeasured: CGFloat = 0

    /// Initial estimate for the chrome above the result list; replaced by a
    /// live measurement once the view lays out.
    private static let chromeHeight: CGFloat = 240
    private static let defaultSize = NSSize(width: 500, height: 360)
    /// Floor for content-driven fit. Kept low so the empty / no-result state
    /// pulls in tight instead of leaving a blank block under the placeholder.
    private static let minFittedHeight: CGFloat = 220
    /// Hard ceiling for content-driven growth. Beyond this the result body
    /// scrolls instead of the window getting taller (also clamped to the
    /// screen). Sized so a single card can grow to its full body height
    /// (`ResultCardView.maxBodyHeight`) with the header/footer still visible.
    private static let maxHeight: CGFloat = 760
    /// Margin kept above and below the panel when it fills a tall screen.
    private static let screenPadding: CGFloat = 24
    /// Slack added to the fitted height: covers a slightly-short content
    /// measurement (so the bottom card's footer never clips) and leaves a little
    /// breathing room below the last card.
    private static let fitBuffer: CGFloat = 36

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
        // Hide all native traffic-light buttons: on this transparent glass panel
        // the red close dot floated detached in the top-left corner. The panel
        // draws its own toolbar (pin / close) instead, and Esc still closes via
        // `cancelOperation` → `onEscape`.
        panel.standardWindowButton(.closeButton)?.isHidden = true
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
            onContentHeightChange: { [weak self] contentHeight in
                guard let self else { return }
                self.resultHeightMeasured = contentHeight
                self.refit()
            },
            onChromeHeightChange: { [weak self] chromeHeight in
                guard let self else { return }
                self.chromeHeightMeasured = chromeHeight
                self.refit()
            },
            onClose: { [weak self] in self?.close() }
        )
        panel.contentView = DraggableHostingView(rootView: root)
    }

    // MARK: - Presentation

    func showInput(prefill: String? = nil, autoTranslate: Bool = false) {
        if let prefill {
            viewModel.inputText = prefill
        }
        // Only place-and-size from scratch for a genuinely fresh panel. The
        // outside-click monitor orders the panel out (isVisible becomes false)
        // between uses, but its content and fitted size are still there — re-
        // showing must keep them, not snap back to the default size.
        if !panel.isVisible, viewModel.run.runs.isEmpty {
            centerOnActiveScreen()
        }
        // Don't force the height here. When a real translation starts, `refit`
        // resizes to fit the new content; when a hotkey fires with nothing to
        // translate (no selection), the existing results stay put instead of
        // the window collapsing to the default height.
        panel.makeKeyAndOrderFront(nil)
        installClickMonitor()
        viewModel.focusToken += 1
        // Fit to the current content now that the panel is on screen. Content
        // measurements that arrived while it was ordered out (e.g. the empty
        // placeholder after clearing) were ignored by `refit`'s visibility
        // guard, so the window could otherwise stay at the wrong height.
        refit()
        if autoTranslate {
            viewModel.translate()
        }
    }

    func close() {
        viewModel.run.cancelAll()
        removeClickMonitor()
        panel.orderOut(nil)
    }

    /// Show the panel with a transient notice (capture failures, hints). Clears
    /// the previous input and results so a failed trigger (e.g. no selection)
    /// shows a clean panel with just the notice — no stale input with an empty
    /// result area under it.
    func showNotice(_ message: String) {
        viewModel.inputText = ""
        viewModel.run.clear()
        showInput()
        viewModel.notice = message
    }

    /// Place the panel on whichever screen the pointer is on (falls back to the
    /// main screen), horizontally centered with its top edge in the upper
    /// portion of the screen. The window is top-anchored, so results stream in
    /// by growing downward into the space below from here.
    private func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = Self.defaultSize
        let topY = visible.maxY - visible.height * 0.16 // top edge ~16% down
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: topY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Size the panel to fit `chrome + result` content, grow and shrink, with
    /// the **top edge pinned**. Results stream in by extending the bottom edge
    /// downward while the input stays put; collapsing/expanding a card likewise
    /// only moves the bottom, so the header stays under the pointer. This avoids
    /// the window jumping around (a centered fit repositions on every change).
    /// Past the ceiling the result body scrolls internally instead of growing.
    private func refit() {
        guard panel.isVisible, !panel.inLiveResize else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }

        let visible = screen.visibleFrame
        let ceiling = min(Self.maxHeight, visible.height - Self.screenPadding * 2)
        // Safety margin: the SwiftUI result-height measurement can land a hair
        // short of the real rendered height (last card's footer), which clipped
        // the bottom card. A small buffer guarantees the last card shows in full.
        let content = chromeHeightMeasured + resultHeightMeasured + Self.fitBuffer
        let desired = min(max(content, Self.minFittedHeight), ceiling)
        guard abs(desired - panel.frame.height) > 4 else { return } // ignore jitter

        var frame = panel.frame
        let topY = frame.maxY // preserve the top edge
        frame.size.height = desired
        frame.origin.y = topY - desired

        // Keep the panel fully on screen; if growing past the bottom, slide up.
        if frame.minY < visible.minY + Self.screenPadding {
            frame.origin.y = visible.minY + Self.screenPadding
        }
        if frame.maxY > visible.maxY - Self.screenPadding {
            frame.origin.y = visible.maxY - Self.screenPadding - desired
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

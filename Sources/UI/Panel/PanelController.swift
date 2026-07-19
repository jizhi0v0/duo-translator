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

    /// Act on the first click even when the panel isn't key. Without this the
    /// non-activating panel eats the first click just to become key, so a
    /// toolbar button (e.g. page mode) needs a wasted second click to register.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the floating translator panel: positioning near the mouse, key-window
/// behavior without activating the app, outside-click dismissal, pinning, and
/// content-driven height growth.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let viewModel = PanelViewModel()

    private var panel: TranslatorPanel!
    private var clickMonitor: Any?
    // Timing instrumentation for the show path (first show pays lazy construction
    // + first SwiftUI/AppKit layout; later shows reuse the panel).
    private var didFirstShow = false
    private var showStart: Date?
    private var awaitingLayoutLog = false

    /// Latest measured heights that drive the window fit: the chrome (everything
    /// above the result list) and the result content. Kept so either changing
    /// re-fits against the current value of the other.
    private var chromeHeightMeasured: CGFloat = chromeHeight
    private var resultHeightMeasured: CGFloat = 0

    /// Initial estimate for the chrome above the result list; replaced by a
    /// live measurement once the view lays out.
    private static let chromeHeight: CGFloat = 240
    private static let defaultSize = NSSize(width: 400, height: 360)
    /// Wider width used in page mode so the bilingual two-column view has room.
    private static let pageModeWidth: CGFloat = 680
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
    /// Floor for the result-list budget (space left for cards after chrome), so
    /// a very tall input still leaves the cards a usable, scrollable minimum.
    private static let minResultBudget: CGFloat = 200
    /// Small rounding-safety slack added to the fitted height so a sub-pixel
    /// short measurement can't clip the bottom card's footer. Kept minimal: the
    /// content measurement tracks the real rendered height exactly, so anything
    /// larger just shows as dead space below the last card. If a late-arriving
    /// measurement is genuinely taller, `refit` grows again to match.
    private static let fitBuffer: CGFloat = 6

    override init() {
        super.init()
        let initStart = Date()
        defer {
            Log.app.debug("面板: init 构造 \(String(format: "%.1f", Date().timeIntervalSince(initStart) * 1000), privacy: .public)ms")
        }

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
        // Become key on any click (not only when a subview needs the keyboard):
        // otherwise the non-activating panel spends the first click just becoming
        // key, so toolbar buttons need a wasted second click to register.
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Liquid Glass: the SwiftUI root draws the panel body as glass, so the
        // window itself must be transparent.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 304, height: 280)
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
                if self.awaitingLayoutLog, let start = self.showStart {
                    self.awaitingLayoutLog = false
                    Log.app.debug("面板: 首次布局到位 show 起 \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000), privacy: .public)ms")
                }
                self.refit()
            },
            onModeChange: { [weak self] pageMode in self?.applyModeWidth(pageMode: pageMode) },
            onClose: { [weak self] in self?.close() }
        )
        let hostingView = DraggableHostingView(rootView: root)
        // With `.titled` + `.fullSizeContentView` the hosting view otherwise
        // inherits a top safe-area inset matching the (transparent) titlebar,
        // which pushes the glass body down and leaves an invisible transparent
        // strip at the very top of the window — dead space that also stops the
        // glass from sitting flush at the top. Clear the safe-area regions so the
        // glass fills to the true top edge.
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView
    }

    /// Resize the panel's width for the current mode, keeping the top edge and
    /// horizontal center fixed and staying on screen. Height is left to `refit`.
    private func applyModeWidth(pageMode: Bool) {
        let targetWidth = pageMode ? Self.pageModeWidth : Self.defaultSize.width
        guard abs(panel.frame.width - targetWidth) > 1 else { return }

        var frame = panel.frame
        let centerX = frame.midX
        frame.origin.x = centerX - targetWidth / 2
        frame.size.width = targetWidth

        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if frame.maxX > visible.maxX - Self.screenPadding {
                frame.origin.x = visible.maxX - Self.screenPadding - targetWidth
            }
            if frame.minX < visible.minX + Self.screenPadding {
                frame.origin.x = visible.minX + Self.screenPadding
            }
        }
        panel.setFrame(frame, display: true, animate: false)
        refit()
        // The mode swap (cards ↔ page view) and the width change both relayout
        // asynchronously; a deferred pass fits the height once the new content
        // has reported its geometry, so the switch settles without a second click.
        DispatchQueue.main.async { [weak self] in self?.refit() }
    }

    // MARK: - Presentation

    func showInput(prefill: String? = nil, autoTranslate: Bool = false) {
        let t0 = Date()
        let firstShow = !didFirstShow
        didFirstShow = true
        showStart = t0
        awaitingLayoutLog = true
        defer {
            Log.app.debug("面板: showInput 同步 \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000), privacy: .public)ms, 首次=\(firstShow, privacy: .public)")
        }
        // Each fresh presentation starts in the compact card mode; page mode is
        // an explicit per-session toggle, not a sticky window state.
        viewModel.pageMode = false
        if let prefill {
            viewModel.inputText = prefill
            // Capture-to-input (取字, no auto translate) starts no run, so the
            // previous run's result cards would linger under the new text — drop
            // them. Don't clear on the auto-translate path: `translate()` →
            // `run.start` replaces the results itself, and clearing here empties
            // `runs`, which trips the `runs.isEmpty` "fresh panel" gate below and
            // snaps the reused panel back to its default size (leaving a gap).
            if !autoTranslate {
                viewModel.run.clear()
                viewModel.notice = nil
            }
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

    /// Prime the panel at launch-idle: constructing this controller already
    /// built the NSPanel + SwiftUI tree; forcing one layout pass pays the
    /// first-layout cost now instead of on the user's first 划词. The window is
    /// never ordered on screen, so nothing flashes and `refit` (visibility-
    /// guarded) is a no-op here.
    func prewarm() {
        let t0 = Date()
        panel.contentView?.layoutSubtreeIfNeeded()
        Log.app.debug("面板: prewarm 布局 \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
    }

    /// UI-test presentation: seed the input and optionally inject fake result
    /// cards (long body text) so tests can verify the result area fits on screen
    /// and scrolls. Seeds after showing so `showInput`'s clear doesn't wipe them;
    /// the cards' geometry callbacks then drive `refit` as in a real translation.
    func uiTestPresent(input: String, resultCount: Int) {
        viewModel.inputText = input
        showInput()
        if resultCount > 0 {
            viewModel.run.uiTestSeedResults(
                count: resultCount,
                text: String(repeating: "结果卡片正文，用于验证长译文时底部可以滚动、不会被遮挡。", count: 40)
            )
        } else {
            viewModel.run.clear()
        }
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

        // Publish how much height is actually left for the result list at this
        // ceiling given the current chrome. The result cards cap their bodies to
        // this, so a tall input shrinks the cards (they scroll internally) and
        // the total always fits the window — instead of the bottom card being
        // pushed off-screen with no reachable scrollbar.
        let budget = max(Self.minResultBudget, ceiling - chromeHeightMeasured - Self.fitBuffer)
        if abs(budget - viewModel.resultAreaBudget) > 1 {
            viewModel.resultAreaBudget = budget
        }

        // Fit chrome + result (+ a small buffer so a hair-short measurement can't
        // clip the last card), clamped to [minFittedHeight, ceiling].
        let desired = PanelLayout.windowHeight(
            chrome: chromeHeightMeasured,
            result: resultHeightMeasured,
            buffer: Self.fitBuffer,
            floor: Self.minFittedHeight,
            ceiling: ceiling
        )
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

/// Pure sizing math for the translator panel, factored out of the SwiftUI views
/// so the height rules can be unit-tested across input lengths (empty → one line
/// → many lines → overflow) without a running UI. No state, no actor isolation —
/// just the formulas the views feed their live measurements into.
enum PanelLayout {
    /// Window height fitted to `chrome + result` (plus `buffer`), clamped to
    /// `[floor, ceiling]`. Grows with content and never exceeds the ceiling.
    static func windowHeight(
        chrome: CGFloat, result: CGFloat, buffer: CGFloat, floor: CGFloat, ceiling: CGFloat
    ) -> CGFloat {
        min(max(chrome + result + buffer, floor), ceiling)
    }

    /// Input editor height: grows with typed content, clamped to `[min, max]`
    /// (past `max` the editor scrolls internally instead of growing).
    static func editorHeight(content: CGFloat, min minH: CGFloat, max maxH: CGFloat) -> CGFloat {
        Swift.min(Swift.max(content, minH), maxH)
    }

    /// Per-card body ceiling: the result-area budget minus each card's
    /// header/footer overhead, split evenly across the cards, floored so a card
    /// never collapses. When above the floor, `count * (body + cardChrome)`
    /// exactly equals `budget`.
    static func perCardBodyMax(
        count: Int, budget: CGFloat, cardChrome: CGFloat, floor: CGFloat
    ) -> CGFloat {
        let n = CGFloat(Swift.max(count, 1))
        return Swift.max(floor, (budget - n * cardChrome) / n)
    }

    // Result body text metrics, mirroring `StreamingTextView` (system font 14,
    // line spacing 3, 8pt vertical text-container inset each side).
    static let bodyLineSpacing: CGFloat = 3
    static let bodyVInset: CGFloat = 8
    static let bodyLineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14))

    /// Largest line-aligned body height ≤ `ceiling`: fits `k` whole lines plus
    /// the top/bottom insets, so a capped body scrolls from a clean line
    /// boundary instead of slicing the last line in half.
    static func lineAlignedBodyHeight(atMost ceiling: CGFloat) -> CGFloat {
        let step = bodyLineHeight + bodyLineSpacing
        let usable = ceiling - bodyVInset * 2
        let k = ((usable + bodyLineSpacing) / step).rounded(.down)
        guard k >= 1 else { return ceiling }
        return bodyVInset * 2 + k * bodyLineHeight + (k - 1) * bodyLineSpacing
    }

    /// Resolved result-body height: at least `min`, growing with the measured
    /// text height, but never past the line-aligned `cap`. Content that fits
    /// shows at its exact height; only overflow is clamped (to a whole-line cap).
    static func resolvedBodyHeight(text: CGFloat, min minH: CGFloat, cap: CGFloat) -> CGFloat {
        Swift.min(Swift.max(text, minH), lineAlignedBodyHeight(atMost: cap))
    }
}

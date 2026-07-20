import AppKit
import SwiftUI

final class TranslatorPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Hosting view for the panel content. Window dragging is NOT window-background
/// based (`isMovableByWindowBackground` is off): with it on, any drag that no
/// interactive control claimed — including the result scrollbars, whose
/// `mouseDownCanMoveWindow` overrides are ignored inside the hosting hierarchy —
/// moved the whole window. Dragging is opted IN instead, only via the toolbar's
/// `WindowDragHandle` (see `PanelRootView`).
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    /// Act on the first click even when the panel isn't key. Without this the
    /// non-activating panel eats the first click just to become key, so a
    /// toolbar button (e.g. page mode) needs a wasted second click to register.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// AppKit view that starts a window drag on mouse-down. Placed behind the
/// toolbar row (and only there), it makes the top chrome the panel's single
/// drag region; buttons layered above it still receive their own clicks.
struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Owns the floating translator panel: positioning near the mouse, key-window
/// behavior without activating the app, outside-click dismissal, pinning, and
/// content-driven height growth.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let viewModel = PanelViewModel()

    private var panel: TranslatorPanel!
    private var clickMonitor: Any?
    // Suppress window re-fitting while the user is actively scrolling a result:
    // resizing the glass panel mid-scroll (as streaming content grows) fights
    // the scroll and drops frames. Deferred fits apply once scrolling settles.
    private var scrollMonitor: Any?
    private var isUserScrolling = false
    private var pendingRefit = false
    private var scrollIdleWork: DispatchWorkItem?
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
    /// Last good measurement for each layout mode, tied to the translation run
    /// that produced it. A completed run can switch back to either mode using
    /// the target mode's own height in the same window-frame update, instead of
    /// briefly stretching the outgoing mode's backing snapshot.
    private struct CachedResultHeight {
        let height: CGFloat
        let runGeneration: Int
    }
    private var cachedResultHeights: [Bool: CachedResultHeight] = [:]
    /// Mode that produced `resultHeightMeasured`. During a cards ↔ page switch,
    /// the outgoing view can report once more after the model has changed; that
    /// stale height must never be fitted against the new layout.
    private var resultMeasurementPageMode = false
    /// Set when the new mode's width is installed before its first height has
    /// arrived. While set, `refit` holds the current window height.
    private var awaitingResultMeasurementForPageMode: Bool?

    /// Initial estimate for the chrome above the result list; replaced by a
    /// live measurement once the view lays out.
    private static let chromeHeight: CGFloat = 240
    private static let defaultSize = NSSize(width: 400, height: 360)
    /// Wider width used in page mode so the bilingual two-column view has room.
    private static let pageModeWidth: CGFloat = 680
    /// Floor for content-driven fit. Kept low so the empty / no-result state
    /// pulls in tight instead of leaving a blank block under the placeholder.
    private static let minFittedHeight: CGFloat = 220
    /// Hard ceiling for content-driven growth (input, card count, expanded
    /// thinking, and page mode). Compact result bodies themselves use stable
    /// viewports and scroll internally instead of resizing while streaming.
    private static let maxHeight: CGFloat = 900
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
        // Dragging is toolbar-only (`WindowDragHandle`). Window-background
        // dragging is explicitly off: it treated any unclaimed drag — notably
        // on the result scrollbars — as a window move, so dragging a scrollbar
        // dragged the whole panel instead of scrolling.
        panel.isMovableByWindowBackground = false
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
            onContentHeightChange: { [weak self] pageMode, contentHeight in
                self?.acceptResultHeight(contentHeight, pageMode: pageMode)
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
        let hostingView = PanelHostingView(rootView: root)
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

        // For a stable, completed run, reuse the target mode's own last height.
        // Width and height are then installed without displaying the in-between
        // frame, so WindowServer never stretches the outgoing backing store.
        if let cached = reusableResultHeight(forPageMode: pageMode) {
            resultHeightMeasured = cached
            resultMeasurementPageMode = pageMode
            awaitingResultMeasurementForPageMode = nil
        } else {
            // If the new SwiftUI view reported before this onChange callback,
            // keep that measurement. Otherwise hold until the first new-mode
            // value arrives; an in-flight translation must not reuse an older
            // page height whose text may have grown while hidden.
            awaitingResultMeasurementForPageMode =
                resultMeasurementPageMode == pageMode ? nil : pageMode
        }

        guard abs(panel.frame.width - targetWidth) > 1 else {
            refit()
            return
        }

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
        // Neither intermediate frame is displayed: `refit` applies a cached
        // target-mode height when available, then the newly-created SwiftUI /
        // AppKit subtree is laid out and painted before the next window flush.
        panel.setFrame(frame, display: false, animate: false)
        refit(display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.needsDisplay = true
        panel.displayIfNeeded()
        panel.invalidateShadow()
        // The mode swap (cards ↔ page view) and the width change both relayout
        // asynchronously; a deferred pass fits the height once the new content
        // has reported its geometry, so the switch settles without a second click.
        DispatchQueue.main.async { [weak self] in self?.refit() }
    }

    /// Accept only a measurement produced by the currently-visible mode. The
    /// mode view can be created before `onModeChange` runs, so if its width is
    /// not installed yet we cache the value but defer fitting until the width
    /// update makes the two pieces of layout state consistent.
    private func acceptResultHeight(_ height: CGFloat, pageMode: Bool) {
        guard pageMode == viewModel.pageMode else { return }
        resultHeightMeasured = height
        resultMeasurementPageMode = pageMode
        cachedResultHeights[pageMode] = CachedResultHeight(
            height: height,
            runGeneration: viewModel.run.runGeneration
        )
        if awaitingResultMeasurementForPageMode == pageMode {
            awaitingResultMeasurementForPageMode = nil
        }

        let targetWidth = pageMode ? Self.pageModeWidth : Self.defaultSize.width
        guard abs(panel.frame.width - targetWidth) <= 1 else { return }
        refit()
    }

    /// Cached measurements are safe for an unchanged, settled run. Streaming
    /// output can change while its mode is hidden, so that path always waits for
    /// a fresh TextKit/SwiftUI measurement instead of flashing a stale height.
    private func reusableResultHeight(forPageMode pageMode: Bool) -> CGFloat? {
        guard !viewModel.run.runs.isEmpty,
              viewModel.run.runs.allSatisfy({ run in
                  if case .streaming = run.state { return false }
                  return true
              }),
              let cached = cachedResultHeights[pageMode],
              cached.runGeneration == viewModel.run.runGeneration else { return nil }
        return min(cached.height, viewModel.resultAreaBudget)
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
                viewModel.clearNotice()
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
    func uiTestPresent(
        input: String,
        resultCount: Int,
        streaming: Bool = false,
        resultText: String? = nil
    ) {
        viewModel.inputText = input
        showInput()
        if resultCount > 0 {
            let seededText = resultText ?? String(
                repeating: "结果卡片正文，用于验证长译文时底部可以滚动、不会被遮挡。",
                count: 40
            )
            viewModel.run.uiTestSeedResults(
                count: resultCount,
                text: seededText,
                streaming: streaming
            )
            if streaming, resultText != nil {
                viewModel.run.uiTestStreamFirstResult(text: seededText)
            }
        } else {
            viewModel.run.clear()
        }
    }

    /// Show the panel with a transient notice (capture failures, hints). Clears
    /// the previous input and results so a failed trigger (e.g. no selection)
    /// shows a clean panel with just the notice — no stale input with an empty
    /// result area under it.
    func showNotice(_ message: String, action: PanelNoticeAction? = nil) {
        viewModel.inputText = ""
        viewModel.run.clear()
        showInput()
        viewModel.notice = message
        viewModel.noticeAction = action
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
    private func refit(display: Bool = true) {
        guard panel.isVisible, !panel.inLiveResize else { return }
        // Don't resize under the user's fingers: hold the fit and re-apply it
        // when the scroll settles (see `noteUserScroll`).
        if isUserScrolling {
            pendingRefit = true
            return
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }

        let visible = screen.visibleFrame
        // Pin the top edge. Growth is capped to the space *below* the current top,
        // not the full screen height — otherwise a window that opened partway down
        // the screen grows past the bottom, and the on-screen clamp below slides
        // the whole window up, moving the "fixed" top and reading as the entire
        // window scrolling while a provider streams. Anything past this cap scrolls
        // inside the result cards (their budget shrinks with the ceiling), so the
        // top never moves.
        let topEdge = panel.frame.maxY
        let availableBelowTop = topEdge - visible.minY - Self.screenPadding
        let ceiling = min(Self.maxHeight, max(Self.minFittedHeight, availableBelowTop))

        // Publish how much height is actually left for the result list at this
        // ceiling given the current chrome. The result cards cap their bodies to
        // this, so a tall input shrinks the cards (they scroll internally) and
        // the total always fits the window — instead of the bottom card being
        // pushed off-screen with no reachable scrollbar.
        let budget = max(Self.minResultBudget, ceiling - chromeHeightMeasured - Self.fitBuffer)
        if abs(budget - viewModel.resultAreaBudget) > 1 {
            viewModel.resultAreaBudget = budget
        }

        // A mode switch is a two-part update: install the new width, then wait
        // for that mode's content to report at the new layout. Holding here
        // prevents the visible short → tall flash caused by fitting the outgoing
        // mode's cached result height in between those two events.
        guard PanelLayout.canUseResultMeasurement(
            measuredForPageMode: resultMeasurementPageMode,
            currentPageMode: viewModel.pageMode,
            awaitingNewMeasurement: awaitingResultMeasurementForPageMode != nil
        ) else { return }

        // Fit chrome + result (+ a small buffer so a hair-short measurement can't
        // clip the last card), clamped to [minFittedHeight, ceiling]. Compact
        // cards report a stable height while their text streams.
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
        panel.setFrame(frame, display: display, animate: false)
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
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.noteUserScroll()
                return event
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        scrollIdleWork?.cancel()
        scrollIdleWork = nil
        isUserScrolling = false
        pendingRefit = false
    }

    /// Mark scrolling active and (re)arm the idle timer. `refit` no-ops while
    /// this is set; when scrolling has been quiet ~200ms, apply any fit that
    /// was deferred so the window catches up to the content once.
    private func noteUserScroll() {
        isUserScrolling = true
        scrollIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isUserScrolling = false
            if self.pendingRefit {
                self.pendingRefit = false
                self.refit()
            }
        }
        scrollIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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
    /// A result height is fit only when it belongs to the visible mode and no
    /// first measurement for that mode is outstanding.
    static func canUseResultMeasurement(
        measuredForPageMode: Bool,
        currentPageMode: Bool,
        awaitingNewMeasurement: Bool
    ) -> Bool {
        !awaitingNewMeasurement && measuredForPageMode == currentPageMode
    }

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

    /// Stable compact-card body height. It is deliberately independent of the
    /// streamed text length: content growth must scroll inside the card instead
    /// of moving every card below it and resizing the panel on each new line.
    static func stableBodyHeight(preferred: CGFloat, cap: CGFloat) -> CGFloat {
        lineAlignedBodyHeight(atMost: Swift.min(preferred, cap))
    }

    /// Smallest line-aligned body height ≥ `target`: rounds a raw glyph
    /// measurement UP to the next whole-line boundary. A card whose frame
    /// follows the stream snaps line-by-line (never a fractional height that
    /// looks stiff), and rounding up — never down — guarantees the frame is at
    /// least as tall as the real content, so it grows instead of clipping.
    static func lineCeiledBodyHeight(atLeast target: CGFloat) -> CGFloat {
        let step = bodyLineHeight + bodyLineSpacing
        let usable = target - bodyVInset * 2
        let k = Swift.max(1, ((usable + bodyLineSpacing) / step).rounded(.up))
        return bodyVInset * 2 + k * bodyLineHeight + (k - 1) * bodyLineSpacing
    }
}

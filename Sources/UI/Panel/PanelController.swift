import AppKit
import SwiftUI

final class TranslatorPanel: NSPanel {
    static let screenPadding: CGFloat = 24
    /// Approximate height of the toolbar rows at the top of the panel — the
    /// window's grab region. Cross-screen dragging keeps this band reachable.
    static let toolbarBandHeight: CGFloat = 36
    var onEscape: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// Double-click on the toolbar's empty drag area: back to the default
    /// placement (mirrors the card divider's double-click-to-auto).
    var onDragHandleDoubleClick: (() -> Void)?

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

/// AppKit view that moves the window by the pointer's exact screen-space delta.
/// It deliberately does not call `NSWindow.performDrag(with:)`: that hands the
/// gesture to WindowServer, which constrains a titled window back toward a
/// screen when the pointer keeps moving off-screen. Placed behind the toolbar
/// row, this remains the panel's single drag region.
struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        private var startMouseLocation: NSPoint?
        private var startWindowOrigin: NSPoint?

        override func mouseDown(with event: NSEvent) {
            guard let panel = window as? TranslatorPanel else { return }
            if event.clickCount == 2 {
                startMouseLocation = nil
                startWindowOrigin = nil
                panel.onDragHandleDoubleClick?()
                return
            }
            startMouseLocation = NSEvent.mouseLocation
            startWindowOrigin = panel.frame.origin
            panel.onDragBegan?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let panel = window as? TranslatorPanel,
                  let startMouseLocation,
                  let startWindowOrigin else { return }
            let pointer = NSEvent.mouseLocation
            let proposed = WindowDragState.windowOrigin(
                startOrigin: startWindowOrigin,
                startPointer: startMouseLocation,
                currentPointer: pointer
            )
            let screen = NSScreen.screens.first {
                NSMouseInRect(pointer, $0.frame, false)
            } ?? panel.screen ?? NSScreen.main
            let origin = screen.map {
                WindowDragState.dragOrigin(
                    proposed: proposed,
                    windowSize: panel.frame.size,
                    toolbarBandHeight: TranslatorPanel.toolbarBandHeight,
                    pointerScreen: $0.visibleFrame,
                    screens: NSScreen.screens.map(\.visibleFrame)
                )
            } ?? proposed
            // Whole-pixel origins: trackpad deltas are fractional, and a
            // sub-pixel window origin shimmers text on non-Retina displays.
            let aligned = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
            // At a screen edge the pointer can keep moving while the constrained
            // window origin stays unchanged. Re-sending that same frame causes
            // AppKit to relayout first-responder text/scroll views, which can
            // autoscroll their contents even though the window is stationary.
            guard abs(aligned.x - panel.frame.origin.x) > 0.5
                    || abs(aligned.y - panel.frame.origin.y) > 0.5 else { return }
            panel.setFrameOrigin(aligned)
            panel.onDragMoved?()
        }

        override func mouseUp(with event: NSEvent) {
            endDrag()
        }

        private func endDrag() {
            guard startMouseLocation != nil else { return }
            startMouseLocation = nil
            startWindowOrigin = nil
            (window as? TranslatorPanel)?.onDragEnded?()
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
    /// While true, outside clicks don't dismiss the panel — set when the OCR image
    /// viewer (a separate window) is open so interacting with it can't close this.
    private var suppressOutsideClose = false
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
    /// Interactive window-move lifecycle. Moving a window is not an AppKit live
    /// resize, so `refit` keys off this phase instead: `.dragging` while the
    /// pointer is held (window frame, card geometry and scroll offsets all
    /// frozen; the stream keeps rendering inside those fixed viewports), then
    /// `.settling` for the short window in which SwiftUI/TextKit publish the
    /// measurements cached during the gesture, consumed by one catch-up fit.
    /// Only `.idle` may mutate window geometry.
    private enum WindowDragPhase { case idle, dragging, settling }
    private var windowDragPhase: WindowDragPhase = .idle
    /// Invalidates a superseded gesture's pending settle turns: re-grabbing the
    /// panel during `.settling` must not let the previous gesture's async
    /// blocks unfreeze the new drag mid-hold.
    private var windowDragGeneration = 0
    /// Fallback for a mouse-up lost during deactivation: the normal path ends
    /// directly in `DragView.mouseUp(with:)`.
    private var windowDragReleasePoller: Timer?
    /// AppKit scroll views can autoscroll when a held window-drag pointer moves
    /// beyond their visible bounds. Snapshot every scroll position at mouse-down
    /// and restore it for the entire gesture, so a window drag can never mutate
    /// input/result reading positions.
    @MainActor
    private final class FrozenScrollPosition {
        weak var scrollView: NSScrollView?
        let origin: NSPoint

        init(scrollView: NSScrollView) {
            self.scrollView = scrollView
            self.origin = scrollView.contentView.bounds.origin
        }
    }
    private var frozenScrollPositions: [ObjectIdentifier: FrozenScrollPosition] = [:]

    /// Initial estimate for the chrome above the result list; replaced by a
    /// live measurement once the view lays out.
    private static let chromeHeight: CGFloat = 240
    private static let defaultSize = NSSize(width: 480, height: 360)
    /// Wider width used in page mode so the bilingual two-column view has room.
    private static let pageModeWidth: CGFloat = 680
    /// Floor for content-driven fit. Kept low so the empty / no-result state
    /// pulls in tight instead of leaving a blank block under the placeholder.
    private static let minFittedHeight: CGFloat = 220
    /// Margin kept above and below the panel when it fills a tall screen.
    private static let screenPadding = TranslatorPanel.screenPadding
    /// Small rounding-safety slack added to the fitted height so a sub-pixel
    /// short measurement can't clip the bottom card's footer. Kept minimal: the
    /// content measurement tracks the real rendered height exactly, so anything
    /// larger just shows as dead space below the last card. If a late-arriving
    /// measurement is genuinely taller, `refit` grows again to match.
    private static let fitBuffer: CGFloat = 6
    /// Smallest result strip kept visible while cards exist: one card's chrome
    /// (90) + a one-line body (40) + the list's vertical padding (20). A panel
    /// parked at the very bottom lifts by this shortfall instead of squeezing
    /// the result area to zero height.
    private static let minVisibleResultStrip: CGFloat = 150

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
        panel.isMovable = false
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
        // Low hard floor so it never binds: `refit` governs height (its own
        // `minFittedHeight` keeps normal panels tall; the OCR recognizing state
        // fits tight to its content with no gap). A higher minSize would pad the
        // recognizing panel up and leave dead space under the language bar.
        panel.minSize = NSSize(width: 304, height: 120)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        panel.onDragBegan = { [weak self] in self?.beginWindowDrag() }
        panel.onDragMoved = { [weak self] in self?.restoreScrollPositions() }
        panel.onDragEnded = { [weak self] in self?.finishWindowDrag() }
        panel.onDragHandleDoubleClick = { [weak self] in self?.resetPanelPosition() }

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
        // `refit` is the sole authority on the window's size. By default the
        // hosting view feeds the SwiftUI content's min/intrinsic/max size into the
        // window's constraints — which clamped the window's minimum height to the
        // content `minHeight` (≈220), so a tightly-fitted state (e.g. the OCR
        // recognizing panel with a short chrome) got padded up, leaving a gap
        // under the language bar. Detach it so `setFrame` fully controls height.
        hostingView.sizingOptions = []
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
        // A non-OCR open drops any lingering OCR session so a 划词 / plain-input
        // panel never shows a stale screenshot attachment.
        viewModel.ocr = nil
        viewModel.ocrRecognizing = false
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
        presentPanel()
        if autoTranslate {
            viewModel.translate()
        }
    }

    /// Show the OCR panel immediately (before recognition runs): the captured
    /// image as a left column with a `.recognizing` right side, the panel widened
    /// to fit both. Returns the session so the caller fills in text / marks failure
    /// once `provider.recognize` returns. The recognized text and its translation
    /// then render in the right column in place — no window switch.
    func showOCR(cgImage: CGImage) -> OCRSession {
        viewModel.inputText = ""
        viewModel.run.clear()
        viewModel.clearNotice()
        let session = OCRSession(cgImage: cgImage)
        viewModel.ocr = session
        viewModel.ocrRecognizing = true
        presentPanel()
        // On the panel's first key activation AppKit auto-selects the (then still
        // editable) input as first responder, blinking a caret over "识别中…".
        // Clear it once the disabled state has applied; SwiftUI won't re-focus
        // because `inputFocused` is false while recognizing.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewModel.ocrRecognizing else { return }
            self.panel.makeFirstResponder(nil)
        }
        return session
    }

    /// Order the panel on screen and fit it to the current content. Shared by the
    /// input / OCR presentations so both center, key, focus and refit consistently.
    private func presentPanel() {
        // A newly opened panel returns to automatic content fitting. A drag
        // during the previous visible session must not leak its frozen state
        // into this presentation.
        if !panel.isVisible {
            cancelWindowDrag()
        }
        // Each fresh presentation starts in the compact card mode; page mode is
        // an explicit per-session toggle, not a sticky window state.
        viewModel.pageMode = false
        // Only place-and-size from scratch for a genuinely fresh panel. The
        // outside-click monitor orders the panel out (isVisible becomes false)
        // between uses, but its content and fitted size are still there — re-
        // showing must keep them, not snap back to the default size.
        if !panel.isVisible, viewModel.run.runs.isEmpty {
            placeOnActiveScreen()
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
    }

    func close() {
        cancelWindowDrag()
        viewModel.run.cancelAll()
        // Closing the panel ends the OCR session too: drop the image attachment.
        viewModel.ocr = nil
        viewModel.ocrRecognizing = false
        removeClickMonitor()
        panel.orderOut(nil)
    }

    /// Suppress outside-click dismissal while a child window (the OCR image
    /// viewer) is open, so clicking that window can't close the panel underneath.
    func setSuppressOutsideClose(_ suppress: Bool) {
        suppressOutsideClose = suppress
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
    /// main screen): at the position the user last dragged it to on that screen,
    /// else horizontally centered with the top edge at the padded screen top.
    /// The window is top-anchored, so results stream in by growing downward.
    private func placeOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = Self.defaultSize

        if let saved = SettingsStore.shared.panelTopLeft(forScreen: Self.screenKey(for: screen)) {
            // Clamp a stale corner (resolution/arrangement change since it was
            // saved) back inside instead of opening off-screen.
            let origin = WindowDragState.constrainedOrigin(
                proposed: NSPoint(x: saved.x, y: saved.y - size.height),
                windowSize: size,
                visibleFrame: visible,
                padding: 0
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
            Log.app.notice("面板位置: 恢复 (x=\(Int(origin.x), privacy: .public), top=\(Int(origin.y + size.height), privacy: .public)) @\(Self.screenKey(for: screen), privacy: .public)")
            return
        }

        // Default: open at the padded top so even the maximum fitted height
        // reaches exactly to the padded bottom — no later vertical correction,
        // so every user-chosen position can be preserved.
        let topY = visible.maxY - Self.screenPadding
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: topY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Stable identity for a screen across launches: the CoreGraphics display
    /// id, falling back to the pixel size when unavailable.
    static func screenKey(for screen: NSScreen) -> String {
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(id.uint32Value)"
        }
        return "screen-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    /// Persist where the user put the panel (top-left corner, per screen) so
    /// the next fresh presentation opens right there.
    private func saveDraggedPanelPosition() {
        guard let screen = panelScreen else { return }
        let frame = panel.frame
        SettingsStore.shared.setPanelTopLeft(
            NSPoint(x: frame.origin.x, y: frame.maxY),
            forScreen: Self.screenKey(for: screen)
        )
        Log.app.notice("面板位置: 记住 (x=\(Int(frame.origin.x), privacy: .public), top=\(Int(frame.maxY), privacy: .public)) @\(Self.screenKey(for: screen), privacy: .public)")
    }

    /// Double-click on the toolbar's empty drag area: forget the remembered
    /// position for this screen and go back to the default top-center spot.
    private func resetPanelPosition() {
        cancelWindowDrag()
        guard let screen = panelScreen else { return }
        SettingsStore.shared.clearPanelTopLeft(forScreen: Self.screenKey(for: screen))
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.maxY - Self.screenPadding - frame.height
        panel.setFrame(frame, display: true, animate: false)
        Log.app.notice("面板位置: 重置默认 @\(Self.screenKey(for: screen), privacy: .public)")
        refit()
    }

    /// Size the panel to fit `chrome + result` content, grow and shrink, with
    /// the **top edge pinned**: results stream downward while the input stays
    /// put, and a user-dragged top edge is preserved — growth fills the room
    /// below it, stops at the screen bottom, and past that the bodies scroll
    /// instead of the panel sliding up.
    private func refit(display: Bool = true) {
        guard panel.isVisible, !panel.inLiveResize else { return }
        // No geometry mutation during a window drag. While `.dragging`, even
        // changing the cards' scroll budget makes the contents appear to slide;
        // `.settling` holds everything until the one catch-up fit consumes the
        // measurements cached during the gesture.
        guard windowDragPhase == .idle else { return }
        guard let screen = panelScreen else { return }

        let visible = screen.visibleFrame
        let ceiling = max(
            Self.minFittedHeight,
            visible.height - Self.screenPadding * 2
        )
        // The fit may fill the room below the user's chosen top edge — never
        // more, so fitting can't undo a drag (long content used to grow past
        // the screen bottom and get shoved back up to fill the screen on
        // release). This never runs mid-drag, so the old pathology — a toolbar
        // below the visible frame turning negative room into a minimum-height
        // strip — can't come back. The floors are need-driven: a panel parked
        // at the very bottom lifts only by the shortfall that keeps
        // `minFittedHeight` and an unclipped chrome, never a full-screen jump.
        let resultFloor: CGFloat =
            viewModel.run.runs.isEmpty || viewModel.ocrRecognizing ? 0 : Self.minVisibleResultStrip
        let allowed = PanelLayout.allowedFitHeight(
            roomBelowTop: panel.frame.maxY - visible.minY,
            screenCeiling: ceiling,
            minHeight: Self.minFittedHeight,
            chrome: chromeHeightMeasured + Self.fitBuffer,
            resultFloor: resultFloor
        )

        // Publish how much height is actually left for the result list at that
        // allowance given the current chrome. The page reader and the card
        // bodies size their internal scroll viewport to this, so it must NOT
        // exceed the room the window can show — a floor above the real room
        // (the old `minResultBudget = 200`) pushed the viewport past the
        // window's bottom edge, clipped and unreachable.
        let budget = max(0, allowed - chromeHeightMeasured - Self.fitBuffer)
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
        // clip the last card), clamped to [minFittedHeight, ceiling].
        // While recognizing there's no result list — fit tight to the chrome (no
        // minimum-height padding) so nothing dead-space sits under the language
        // bar. Every other state keeps the normal floor.
        let floor = viewModel.ocrRecognizing ? 0 : Self.minFittedHeight
        let desired = PanelLayout.windowHeight(
            chrome: chromeHeightMeasured,
            result: resultHeightMeasured,
            buffer: Self.fitBuffer,
            floor: floor,
            ceiling: allowed
        )
        guard abs(desired - panel.frame.height) > 4 else { return } // ignore jitter

        var frame = panel.frame
        let topY = frame.maxY // preserve the top edge
        frame.size.height = desired
        frame.origin.y = topY - desired

        // Safety net: `allowed` already stops growth at the screen bottom, so
        // this fires only for the need-driven floors (panel parked at the very
        // bottom), lifting by exactly that shortfall. The multi-screen rule
        // keeps a straddling panel's x untouched instead of shoving it into
        // one display.
        frame.origin = WindowDragState.dragOrigin(
            proposed: frame.origin,
            windowSize: frame.size,
            toolbarBandHeight: TranslatorPanel.toolbarBandHeight,
            pointerScreen: visible,
            screens: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrame(frame, display: display, animate: false)
    }

    /// Freeze only geometry/scroll offsets for the application-controlled drag;
    /// TextKit keeps rendering the live stream inside those fixed viewports. On
    /// release, consume all cached measurements in one catch-up fit.
    private func beginWindowDrag() {
        guard windowDragPhase != .dragging else { return }
        // Supersede any settle turns still pending from the previous gesture:
        // they must not unfreeze this one mid-hold.
        windowDragGeneration += 1
        captureScrollPositions()
        viewModel.windowDragActive = true
        windowDragPhase = .dragging
        Log.app.notice("面板拖拽: begin frame=\(String(describing: self.panel.frame), privacy: .public)")

        let poller = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(pollWindowDragRelease),
            userInfo: nil,
            repeats: true
        )
        windowDragReleasePoller = poller
        RunLoop.main.add(poller, forMode: .common)
    }

    @objc private func pollWindowDragRelease() {
        if leftMouseGestureIsActive {
            restoreScrollPositions()
            return
        }
        finishWindowDrag()
    }

    private func finishWindowDrag() {
        guard windowDragPhase == .dragging else { return }
        restoreScrollPositions()
        windowDragReleasePoller?.invalidate()
        windowDragReleasePoller = nil
        windowDragPhase = .settling
        windowDragGeneration += 1
        let generation = windowDragGeneration
        // First release the card viewport lock. Streaming has remained visible
        // throughout the drag, so every text view already contains the latest
        // glyphs and its cached natural height is ready to apply. The
        // generation guards drop this settle pass if a new grab supersedes it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windowDragGeneration == generation else { return }
            self.viewModel.windowDragActive = false
            self.panel.contentView?.layoutSubtreeIfNeeded()
            self.restoreScrollPositions()

            // Geometry preferences arrive after that SwiftUI pass. Hold every
            // intermediate callback, then consume the latest values in one
            // window-frame update on the following turn.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.windowDragGeneration == generation else { return }
                self.panel.contentView?.layoutSubtreeIfNeeded()
                self.windowDragPhase = .idle
                self.refit()
                self.restoreScrollPositions()
                self.frozenScrollPositions.removeAll()
                self.saveDraggedPanelPosition()
                Log.app.notice("面板拖拽: end refitted frame=\(String(describing: self.panel.frame), privacy: .public)")
            }
        }
    }

    /// Drop all drag state without a settle pass — for close and re-present,
    /// where the next `refit` should simply run under normal rules.
    private func cancelWindowDrag() {
        windowDragGeneration += 1
        windowDragReleasePoller?.invalidate()
        windowDragReleasePoller = nil
        windowDragPhase = .idle
        viewModel.windowDragActive = false
        frozenScrollPositions.removeAll()
    }

    private func captureScrollPositions() {
        frozenScrollPositions.removeAll()
        guard let contentView = panel.contentView else { return }
        for scrollView in scrollViews(in: contentView) {
            frozenScrollPositions[ObjectIdentifier(scrollView)] = FrozenScrollPosition(
                scrollView: scrollView
            )
        }
    }

    private func restoreScrollPositions() {
        guard let contentView = panel.contentView else { return }
        for scrollView in scrollViews(in: contentView) {
            let identifier = ObjectIdentifier(scrollView)
            let frozen: FrozenScrollPosition
            if let existing = frozenScrollPositions[identifier] {
                frozen = existing
            } else {
                // A streamed SwiftUI update may create a new scroll view during
                // the gesture. Freeze it at the first position we observe.
                let created = FrozenScrollPosition(scrollView: scrollView)
                frozenScrollPositions[identifier] = created
                frozen = created
            }
            let clipView = scrollView.contentView
            guard abs(clipView.bounds.origin.x - frozen.origin.x) > 0.5
                    || abs(clipView.bounds.origin.y - frozen.origin.y) > 0.5 else { continue }
            clipView.scroll(to: frozen.origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func scrollViews(in root: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scrollView = root as? NSScrollView {
            result.append(scrollView)
        }
        for subview in root.subviews {
            result.append(contentsOf: scrollViews(in: subview))
        }
        return result
    }

    /// WindowServer can report `buttonState == false` while it owns an AppKit
    /// window drag. Event order remains stable: down is newer while held; up is
    /// newer only after release.
    private var leftMouseGestureIsActive: Bool {
        let downAge = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .leftMouseDown
        )
        let upAge = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .leftMouseUp
        )
        return WindowDragState.isActive(downEventAge: downAge, upEventAge: upAge)
    }

    /// Prefer the screen containing the panel; a fully off-screen drop has no
    /// such screen, so use the screen under the pointer before falling back to
    /// the main display.
    private var panelScreen: NSScreen? {
        panel.screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    // MARK: - Dismissal

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.viewModel.isPinned else { return }
                // While a modal-ish child (the OCR image viewer) is up, clicks on
                // it land outside the panel; don't let them dismiss the panel.
                if self.suppressOutsideClose { return }
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

    /// Catch every interactive window move at the NSWindow layer. The native
    /// transparent title bar can start a move without hitting `WindowDragHandle`,
    /// so observing only the SwiftUI/AppKit drag view misses the common path.
    func windowWillMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel,
              leftMouseGestureIsActive else { return }
        beginWindowDrag()
    }

    /// Usually the common-mode poller sees release first; this is a zero-delay
    /// fallback for AppKit configurations that send a final did-move callback.
    /// Even if `windowWillMove` was bypassed, a completed move still gets one
    /// position-independent fit pass and cannot remain below the visible frame.
    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        switch windowDragPhase {
        case .dragging:
            pollWindowDragRelease()
        case .settling:
            break // the catch-up fit is already scheduled
        case .idle:
            DispatchQueue.main.async { [weak self] in self?.refit() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelWindowDrag()
        removeClickMonitor()
    }
}

/// Pure event-order rule used by the WindowServer-owned drag. Comparing event
/// ages is more dependable here than querying the instantaneous button bit.
enum WindowDragState {
    static func isActive(downEventAge: TimeInterval, upEventAge: TimeInterval) -> Bool {
        downEventAge < upEventAge
    }

    /// Exact translation used by the custom drag. Intentionally unclamped: a
    /// pointer delta of -900pt moves the panel -900pt, even across a screen edge.
    static func windowOrigin(
        startOrigin: NSPoint,
        startPointer: NSPoint,
        currentPointer: NSPoint
    ) -> NSPoint {
        NSPoint(
            x: startOrigin.x + currentPointer.x - startPointer.x,
            y: startOrigin.y + currentPointer.y - startPointer.y
        )
    }

    /// Keep the whole panel inside the usable screen. When the pointer keeps
    /// moving beyond an edge the panel simply stops there; it never slides under
    /// the Dock/menu bar and never needs a later corrective jump.
    static func constrainedOrigin(
        proposed: NSPoint,
        windowSize: NSSize,
        visibleFrame: NSRect,
        padding: CGFloat
    ) -> NSPoint {
        let minX = visibleFrame.minX + padding
        let maxX = max(minX, visibleFrame.maxX - padding - windowSize.width)
        let minY = visibleFrame.minY + padding
        let maxY = max(minY, visibleFrame.maxY - padding - windowSize.height)
        return NSPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }

    /// Constraint across the whole display arrangement. Vertically the window
    /// stays fully inside the host screen (it never slides under the Dock or
    /// menu bar). Horizontally it may span every screen whose usable frame also
    /// contains its toolbar rows — wherever it can still be grabbed — so a
    /// side-by-side crossing tracks the pointer smoothly instead of teleporting
    /// into the new screen the moment the pointer crosses the seam.
    static func dragOrigin(
        proposed: NSPoint,
        windowSize: NSSize,
        toolbarBandHeight: CGFloat,
        pointerScreen: NSRect,
        screens: [NSRect]
    ) -> NSPoint {
        let minY = pointerScreen.minY
        let maxY = max(minY, pointerScreen.maxY - windowSize.height)
        let y = min(max(proposed.y, minY), maxY)

        let bandMinY = y + windowSize.height - toolbarBandHeight
        let bandMaxY = y + windowSize.height
        var hosts = screens.filter { $0.minY <= bandMinY && $0.maxY >= bandMaxY }
        if hosts.isEmpty { hosts = [pointerScreen] }
        let minX = hosts.map(\.minX).min() ?? pointerScreen.minX
        let maxX = max(minX, (hosts.map(\.maxX).max() ?? pointerScreen.maxX) - windowSize.width)
        let x = min(max(proposed.x, minX), maxX)

        // Non-adjacent arrangements can leave a void inside the union span.
        // If the toolbar band would end up grabbable on no screen, fall back
        // to plain containment in the host screen.
        let band = NSRect(x: x, y: bandMinY, width: windowSize.width, height: bandMaxY - bandMinY)
        let grabbable = hosts.contains { host in
            let overlap = band.intersection(host)
            return overlap.width >= 60 && overlap.height >= toolbarBandHeight - 1
        }
        guard grabbable else {
            return constrainedOrigin(
                proposed: proposed, windowSize: windowSize,
                visibleFrame: pointerScreen, padding: 0
            )
        }
        return NSPoint(x: x, y: y)
    }
}

/// Pure sizing math for the translator panel, factored out of the SwiftUI views
/// so the height rules can be unit-tested across input lengths (empty → one line
/// → many lines → overflow) without a running UI. No state, no actor isolation —
/// just the formulas the views feed their live measurements into.
enum PanelLayout {
    /// A list grows with its card stack until the remaining result budget is
    /// filled; overflow belongs to the list's own scroll view, never outside the
    /// window. Zero budget legitimately produces a zero-height viewport.
    static func scrollViewportHeight(content: CGFloat, budget: CGFloat) -> CGFloat {
        min(max(0, content), max(0, budget))
    }

    /// Height ceiling for a fit at rest. The room below the panel's current top
    /// edge preserves the user's placement; the floors are need-driven — the
    /// overall minimum, and the chrome plus a minimum result strip (the input
    /// must not be clipped, and existing cards must not be squeezed to zero,
    /// by a panel parked at the screen bottom) — each lifting the panel by at
    /// most its own shortfall. Never exceeds the screen's usable ceiling.
    static func allowedFitHeight(
        roomBelowTop: CGFloat, screenCeiling: CGFloat, minHeight: CGFloat,
        chrome: CGFloat, resultFloor: CGFloat = 0
    ) -> CGFloat {
        Swift.min(screenCeiling, Swift.max(roomBelowTop, Swift.max(minHeight, chrome + resultFloor)))
    }

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
    // 8pt vertical text-container inset each side). `StreamingTextView` reads
    // the line spacing from here so the two can't drift apart.
    static let bodyLineSpacing: CGFloat = 5
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

    /// Reserved compact-card body height before any content measurement: a
    /// line-aligned floor that is claimed as soon as the card appears, so a card
    /// never starts as a sliver and then jumps.
    static func stableBodyHeight(preferred: CGFloat, cap: CGFloat) -> CGFloat {
        lineAlignedBodyHeight(atMost: Swift.min(preferred, cap))
    }

    /// Compact-card body height that follows the streamed content: it starts at
    /// the line-aligned `floor`, grows with the measured natural height, and
    /// stops at `cap` (the card's share of the window), past which the body
    /// scrolls internally instead of pushing the panel taller.
    static func growingBodyHeight(measured: CGFloat?, floor: CGFloat, cap: CGFloat) -> CGFloat {
        let base = stableBodyHeight(preferred: floor, cap: cap)
        guard let measured else { return base }
        // The ceiling is snapped to whole lines so a capped body scrolls from a
        // clean line boundary rather than slicing a line in half.
        let ceiling = lineAlignedBodyHeight(atMost: cap)
        return Swift.min(Swift.max(measured, base), ceiling)
    }

    /// Body height with a user-dragged height taken into account.
    ///
    /// The dragged value is a *ceiling*, not a fixed height: the body still
    /// follows its content, it just stops there. Treating it as fixed meant
    /// every later short translation sat in a tall box of empty space, and the
    /// height had to be reset by hand to get rid of it.
    static func bodyHeight(
        dragged: CGFloat?, measured: CGFloat?, floor: CGFloat, cap: CGFloat
    ) -> CGFloat {
        let ceiling = Swift.min(dragged ?? cap, cap)
        return growingBodyHeight(measured: measured, floor: floor, cap: ceiling)
    }

    /// A drag in progress, clamped to what the window can actually give: never
    /// below one line, never past this card's share of the result area.
    static func clampDraggedBodyHeight(_ height: CGFloat, floor: CGFloat, cap: CGFloat) -> CGFloat {
        let low = stableBodyHeight(preferred: floor, cap: cap)
        let high = lineAlignedBodyHeight(atMost: cap)
        return Swift.min(Swift.max(height, low), Swift.max(low, high))
    }
}

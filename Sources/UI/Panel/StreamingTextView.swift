import AppKit
import SwiftUI

/// Scroll view for a result body. It consumes the wheel while its own text can
/// move, then forwards the gesture to the outer provider-list scroll view at an
/// edge. It deliberately does NOT touch `mouseDownCanMoveWindow` or replace the
/// clip view — doing so broke text selection inside the result.
private final class ResultScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let contentHeight = documentView?.frame.height ?? 0
        let visibleHeight = contentView.bounds.height
        if contentHeight <= visibleHeight + 1 {
            forwardToOuterScrollView(event)
            return
        }
        let y = contentView.bounds.origin.y
        let maxY = contentHeight - visibleHeight
        let dy = event.scrollingDeltaY
        if (dy > 0 && y <= 0) || (dy < 0 && y >= maxY) {
            forwardToOuterScrollView(event)
            return
        }
        super.scrollWheel(with: event)
    }

    private func forwardToOuterScrollView(_ event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView, scrollView !== self {
                scrollView.scrollWheel(with: event)
                return
            }
            ancestor = view.superview
        }
    }
}

/// Height of the currently laid-out document, insets included.
///
/// Deliberately *not* `usageBoundsForTextContainer`: TextKit 2 updates that
/// lazily, so it keeps reporting the previous extent for a beat after the text
/// storage changes. That lag is visible — a card stays at the last run's height
/// while showing only "翻译中…", and a one-shot translation (Apple) overflows a
/// viewport that catches up late. The last layout fragment's frame is always
/// current, and `.ensuresLayout` makes the measurement authoritative.
@MainActor
private func documentHeight(of textView: NSTextView) -> CGFloat? {
    guard let lm = textView.textLayoutManager else { return nil }
    lm.ensureLayout(for: lm.documentRange)
    var bottom: CGFloat = 0
    lm.enumerateTextLayoutFragments(
        from: lm.documentRange.endLocation,
        options: [.reverse, .ensuresLayout]
    ) { fragment in
        bottom = fragment.layoutFragmentFrame.maxY
        return false // the last fragment alone gives the document's bottom
    }
    return bottom + textView.textContainerInset.height * 2
}

/// TextKit 2 backed streaming result view.
///
/// Performance rules (do not break):
/// 1. Append-only: chunks go through `textStorage.append`, the document is
///    never rebuilt.
/// 2. Never touch `NSTextView.layoutManager` — that silently downgrades the
///    view to TextKit 1 and kills viewport-incremental layout.
/// 3. Follow-scroll only while the user is at the bottom.
struct StreamingTextView: NSViewRepresentable {
    let model: StreamingTextModel
    var fontSize: CGFloat = 14
    /// Height at which the host stops growing and this view starts scrolling.
    /// Measurement stops once the content reaches it, so a long stream doesn't
    /// keep paying for whole-document layout on every chunk.
    var heightCeiling: CGFloat = 0
    /// The run has stopped streaming. Flipping this forces one final
    /// measurement, so a finished translation can never be left at a stale
    /// height by the ceiling short-circuit.
    var settled: Bool = false
    /// While the window is being dragged, follow-scroll must not fight the
    /// controller's frozen scroll offsets.
    var suppressFollow: Bool = false
    /// Incremented by the card's jump button: scroll to the bottom once. The
    /// reader then follows the stream for as long as it stays at the bottom.
    var jumpToBottomToken: Int = 0
    /// Natural content height, reported as the stream grows. Opt-in: without a
    /// handler the view never measures.
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// Whether a jump-to-bottom affordance makes sense right now (the content
    /// overflows and the reader is not at the bottom). Dispatched async.
    var onScrollStateChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // NSTextContainer adds 5pt of line-fragment padding on top of
        // `textContainerInset`. Left in, the body text sits at 15pt while the
        // card's header, footer and the "翻译中…" placeholder sit at 10 — visibly
        // misaligned, and the placeholder shifts sideways as the first chunk
        // replaces it. Zero it so the inset is the only inset.
        textView.textContainer?.lineFragmentPadding = 0

        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        // Keep in sync with `PanelLayout.bodyLineSpacing`, which the card's
        // line-aligned height math depends on.
        paragraph.lineSpacing = PanelLayout.bodyLineSpacing
        // Gap after each paragraph (only at line breaks, not on soft wraps) so
        // multi-paragraph translations read with breathing room instead of every
        // line jammed together.
        paragraph.paragraphSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        textView.typingAttributes = attributes

        let scrollView = ResultScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.setup(textView: textView, attributes: attributes)
        context.coordinator.configureHeightReporting(
            ceiling: heightCeiling, settled: settled, handler: onContentHeightChange
        )
        context.coordinator.configureFollow(
            suppressed: suppressFollow, handler: onScrollStateChange
        )
        context.coordinator.applyJumpToken(jumpToBottomToken)
        context.coordinator.bindModel(model)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.configureHeightReporting(
            ceiling: heightCeiling, settled: settled, handler: onContentHeightChange
        )
        context.coordinator.configureFollow(
            suppressed: suppressFollow, handler: onScrollStateChange
        )
        context.coordinator.applyJumpToken(jumpToBottomToken)
        // Each translation run hands the view a fresh StreamingTextModel; without
        // rebinding, only the first run would ever render.
        context.coordinator.bindModel(model)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var textView: NSTextView?
        private var attributes: [NSAttributedString.Key: Any] = [:]
        private weak var model: StreamingTextModel?
        private var onContentHeightChange: ((CGFloat) -> Void)?
        private var heightCeiling: CGFloat = 0
        private var lastReportedHeight: CGFloat = 0
        private var lastWidth: CGFloat = 0
        private var reachedHeightCeiling = false
        private var heightReportScheduled = false
        /// Set where the document may legitimately get shorter (a new run, or a
        /// rewrap); cleared by the next report. See the guard in the report.
        private var allowsShrink = true
        private var hasSettled = false
        private var suppressFollow = false
        private var onScrollStateChange: ((Bool) -> Void)?
        private var lastJumpToken = 0
        private var lastReportedJumpVisible = false

        /// One-time wiring of the views.
        func setup(
            textView: NSTextView,
            attributes: [NSAttributedString.Key: Any]
        ) {
            self.textView = textView
            self.attributes = attributes
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(frameChanged),
                name: NSView.frameDidChangeNotification, object: textView
            )
            if let clip = textView.enclosingScrollView?.contentView {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(scrollBoundsChanged),
                    name: NSView.boundsDidChangeNotification, object: clip
                )
            }
        }

        // MARK: Follow-the-stream

        func configureFollow(suppressed: Bool, handler: ((Bool) -> Void)?) {
            suppressFollow = suppressed
            onScrollStateChange = handler
        }

        /// A raised token means the jump button was clicked: go to the bottom
        /// once; staying there makes subsequent appends follow. A lower token
        /// is a recreated SwiftUI view resyncing — never a jump.
        func applyJumpToken(_ token: Int) {
            guard token != lastJumpToken else { return }
            let increased = token > lastJumpToken
            lastJumpToken = token
            guard increased else { return }
            DispatchQueue.main.async { [weak self] in
                self?.textView?.scrollToEndOfDocument(nil)
                self?.reportScrollState()
            }
        }

        @objc private func scrollBoundsChanged() {
            reportScrollState()
        }

        /// (overflowing, atBottom) for the current viewport.
        private func viewportState() -> (overflowing: Bool, atBottom: Bool) {
            guard let textView, let clip = textView.enclosingScrollView?.contentView else {
                return (false, true)
            }
            let docHeight = textView.frame.height
            let visible = clip.bounds
            let overflowing = docHeight > visible.height + 1
            let atBottom = visible.origin.y >= docHeight - visible.height - 4
            return (overflowing, atBottom)
        }

        private func reportScrollState() {
            guard let handler = onScrollStateChange else { return }
            let state = viewportState()
            let jumpVisible = state.overflowing && !state.atBottom
            guard jumpVisible != lastReportedJumpVisible else { return }
            lastReportedJumpVisible = jumpVisible
            DispatchQueue.main.async { handler(jumpVisible) }
        }

        /// Re-measure after a real width change (panel width switches between
        /// compact and page mode), since wrapping — and so the height — changes.
        @objc private func frameChanged() {
            guard let width = textView?.bounds.width, abs(width - lastWidth) > 1 else { return }
            lastWidth = width
            reachedHeightCeiling = false
            // A rewrap can genuinely make the document shorter (wider view, fewer
            // wrapped lines), so this measurement is allowed to shrink the host.
            allowsShrink = true
            lastReportedHeight = 0
            scheduleHeightReport(force: true)
        }

        func configureHeightReporting(
            ceiling: CGFloat, settled: Bool, handler: ((CGFloat) -> Void)?
        ) {
            onContentHeightChange = handler
            // A raised ceiling means the content may grow further than the last
            // report, so measuring has to resume. The run settling likewise gets
            // one fresh measurement, so a finished translation can never be left
            // at a height the ceiling short-circuit stopped updating.
            let ceilingChanged = abs(ceiling - heightCeiling) > 1
            let justSettled = settled && !hasSettled
            heightCeiling = ceiling
            hasSettled = settled
            guard ceilingChanged || justSettled else { return }
            reachedHeightCeiling = false
            scheduleHeightReport(force: true)
            // Measure again shortly after: a measurement taken while the view is
            // being scrolled can read TextKit's re-estimated layout rather than
            // the real one. The report is monotonic within a run, so this can
            // only correct the height upward, never shrink the card.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.scheduleHeightReport(force: true)
            }
        }

        /// Attach to the run's text model. Called on every SwiftUI update; each
        /// translation run supplies a new model, so we detach the old one, clear
        /// the view, and replay whatever the new model already buffered.
        func bindModel(_ newModel: StreamingTextModel) {
            if newModel === model {
                // Another mode's reader may have temporarily taken ownership of
                // the model's single callback. Reassert it whenever this compact
                // view becomes current again so mid-stream mode switches cannot
                // leave the visible card frozen.
                installCallbacks(on: newModel)
                return
            }
            model?.onAppend = nil
            model?.onReset = nil
            model = newModel

            resetText()
            // Replay only what has been revealed so far; the pacer keeps
            // feeding the rest.
            if !newModel.revealedText.isEmpty {
                append(newModel.revealedText)
            }
            installCallbacks(on: newModel)
        }

        private func scheduleHeightReport(force: Bool) {
            guard onContentHeightChange != nil else { return }
            if reachedHeightCeiling, !force { return }
            guard !heightReportScheduled else { return }
            heightReportScheduled = true
            // No throttle: appends are already paced to one per frame, so this is
            // at most one measurement per frame, and it stops entirely once the
            // body reaches its ceiling. Delaying it is what made the height trail
            // the glyphs by a wrapped line or two.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightReportScheduled = false
                guard let handler = self.onContentHeightChange,
                      let textView = self.textView,
                      let height = documentHeight(of: textView) else { return }
                self.reachedHeightCeiling = height >= self.heightCeiling - 1
                // Within a run the document only grows (appends are the only
                // edit), so a measurement that comes back *shorter* is not the
                // content shrinking — it is TextKit 2 having dropped or
                // re-estimated layout outside the viewport, which is exactly
                // what happens while the view is scrolled hard. Trusting it
                // collapsed the card mid-run. Shrinking is allowed only where
                // the content genuinely can: a new run, or a width change that
                // rewraps the text.
                guard height > self.lastReportedHeight + 1 || self.allowsShrink else { return }
                self.allowsShrink = false
                self.lastReportedHeight = height
                handler(height)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        private func installCallbacks(on model: StreamingTextModel) {
            model.onAppend = { [weak self] chunk in
                self?.append(chunk)
            }
            model.onReset = { [weak self] in
                self?.resetText()
            }
        }

        private func append(_ chunk: String) {
            guard let textView, let storage = textView.textStorage else { return }
            // Terminal-style follow: only when the reader already parked at the
            // bottom of an overflowing body does the view chase the stream. The
            // default reading position (the top) never moves on its own.
            let state = viewportState()
            let follow = !suppressFollow && state.overflowing && state.atBottom
            storage.beginEditing()
            storage.append(NSAttributedString(string: chunk, attributes: attributes))
            storage.endEditing()
            if follow { textView.scrollToEndOfDocument(nil) }
            scheduleHeightReport(force: false)
            reportScrollState()
        }

        private func resetText() {
            guard let textView, let storage = textView.textStorage else { return }
            storage.beginEditing()
            storage.replaceCharacters(
                in: NSRange(location: 0, length: storage.length),
                with: ""
            )
            storage.endEditing()
            textView.scroll(.zero) // new run starts at the top
            // A new run must pull the card back down to its floor, so this is one
            // of the two places a shorter measurement is real.
            lastReportedHeight = 0
            reachedHeightCeiling = false
            allowsShrink = true
            scheduleHeightReport(force: true)
            reportScrollState()
        }
    }
}

/// Streaming reader for page mode, in a TextKit 2 `NSTextView`. It binds directly
/// to `StreamingTextModel` and appends deltas to text storage, so page mode keeps
/// receiving every chunk without asking SwiftUI to rebuild the whole document.
///
/// Uses a plain `NSScrollView` (not `ResultScrollView`): page mode's content is
/// the only scroller, so it needs normal scrolling, not the card list's
/// scroll-chaining/swallow behavior. Reports content height so the page grows
/// then scrolls, like the cards.
struct PageReaderView: NSViewRepresentable {
    let model: StreamingTextModel
    let original: String
    let bilingual: Bool
    let placeholder: String
    /// True once the run stopped streaming. While false, 对照 interleaves only
    /// the paragraphs translated so far (a pure append-only projection); on
    /// settling, the original's unpaired remainder is appended once.
    let streamSettled: Bool
    /// Identity of the underlying run. Scroll resets to the top only when this
    /// changes (a new translation / provider), not on every streaming chunk.
    let resetKey: String
    /// Once natural content reaches this ceiling, further appends no longer need
    /// expensive whole-document height measurements; the reader already scrolls.
    let heightCeiling: CGFloat
    /// While the window is being dragged, follow-scroll must not fight the
    /// controller's frozen scroll offsets.
    var suppressFollow: Bool = false
    /// Incremented by the page's jump button: scroll to the bottom once.
    var jumpToBottomToken: Int = 0
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// Whether a jump-to-bottom affordance makes sense (content overflows and
    /// the reader is not at the bottom). Dispatched async.
    var onScrollStateChange: ((Bool) -> Void)?

    func makeCoordinator() -> ReaderCoordinator { ReaderCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.setAccessibilityIdentifier("page.reader")
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.setup(textView: textView, onContentHeightChange: onContentHeightChange)
        context.coordinator.configureFollow(
            suppressed: suppressFollow, handler: onScrollStateChange
        )
        context.coordinator.applyJumpToken(jumpToBottomToken)
        context.coordinator.configure(
            model: model,
            original: original,
            bilingual: bilingual,
            placeholder: placeholder,
            resetKey: resetKey,
            heightCeiling: heightCeiling,
            streamSettled: streamSettled
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onContentHeightChange = onContentHeightChange
        context.coordinator.configureFollow(
            suppressed: suppressFollow, handler: onScrollStateChange
        )
        context.coordinator.applyJumpToken(jumpToBottomToken)
        context.coordinator.configure(
            model: model,
            original: original,
            bilingual: bilingual,
            placeholder: placeholder,
            resetKey: resetKey,
            heightCeiling: heightCeiling,
            streamSettled: streamSettled
        )
    }

    @MainActor
    final class ReaderCoordinator: NSObject {
        private weak var textView: NSTextView?
        var onContentHeightChange: ((CGFloat) -> Void)?
        private weak var model: StreamingTextModel?
        private var original = ""
        private var bilingual = false
        private var placeholder = ""
        private var resetKey: String?
        private var heightCeiling: CGFloat = 0
        private var streamSettled = false
        private var lastReportedHeight: CGFloat = 0
        private var lastWidth: CGFloat = 0
        private var reachedHeightCeiling = false
        private var heightReportScheduled = false
        /// Set where the document may legitimately get shorter (a new run, or a
        /// rewrap); cleared by the next report. See the guard in the report.
        private var allowsShrink = true
        private var suppressFollow = false
        private var onScrollStateChange: ((Bool) -> Void)?
        private var lastJumpToken = 0
        private var lastReportedJumpVisible = false

        func setup(textView: NSTextView, onContentHeightChange: ((CGFloat) -> Void)?) {
            self.textView = textView
            self.onContentHeightChange = onContentHeightChange
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(frameChanged),
                name: NSView.frameDidChangeNotification, object: textView
            )
            if let clip = textView.enclosingScrollView?.contentView {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(scrollBoundsChanged),
                    name: NSView.boundsDidChangeNotification, object: clip
                )
            }
        }

        // MARK: Follow-the-stream (same rules as the card coordinator)

        func configureFollow(suppressed: Bool, handler: ((Bool) -> Void)?) {
            suppressFollow = suppressed
            onScrollStateChange = handler
        }

        func applyJumpToken(_ token: Int) {
            guard token != lastJumpToken else { return }
            let increased = token > lastJumpToken
            lastJumpToken = token
            guard increased else { return }
            DispatchQueue.main.async { [weak self] in
                self?.textView?.scrollToEndOfDocument(nil)
                self?.reportScrollState()
            }
        }

        @objc private func scrollBoundsChanged() {
            reportScrollState()
        }

        private func viewportState() -> (overflowing: Bool, atBottom: Bool) {
            guard let textView, let clip = textView.enclosingScrollView?.contentView else {
                return (false, true)
            }
            let docHeight = textView.frame.height
            let visible = clip.bounds
            let overflowing = docHeight > visible.height + 1
            let atBottom = visible.origin.y >= docHeight - visible.height - 4
            return (overflowing, atBottom)
        }

        private func reportScrollState() {
            guard let handler = onScrollStateChange else { return }
            let state = viewportState()
            let jumpVisible = state.overflowing && !state.atBottom
            guard jumpVisible != lastReportedJumpVisible else { return }
            lastReportedJumpVisible = jumpVisible
            DispatchQueue.main.async { handler(jumpVisible) }
        }

        @objc private func frameChanged() {
            guard let width = textView?.bounds.width, abs(width - lastWidth) > 1 else { return }
            lastWidth = width
            reachedHeightCeiling = false
            // A rewrap can genuinely make the document shorter (wider view, fewer
            // wrapped lines), so this measurement is allowed to shrink the host.
            allowsShrink = true
            lastReportedHeight = 0
            scheduleHeightReport(force: true)
        }

        /// Rebuild only for a new model or a real presentation change. Normal
        /// streaming bypasses SwiftUI and goes through `append`, preserving the
        /// append-only TextKit path.
        func configure(
            model newModel: StreamingTextModel,
            original newOriginal: String,
            bilingual newBilingual: Bool,
            placeholder newPlaceholder: String,
            resetKey newResetKey: String,
            heightCeiling newHeightCeiling: CGFloat,
            streamSettled newStreamSettled: Bool
        ) {
            let modelChanged = model !== newModel
            let contentConfigurationChanged = original != newOriginal || bilingual != newBilingual
                || streamSettled != newStreamSettled
            let visiblePlaceholderChanged = placeholder != newPlaceholder && newModel.revealedText.isEmpty
            let shouldRebuild = modelChanged || contentConfigurationChanged || visiblePlaceholderChanged
            let shouldResetScroll = modelChanged || resetKey != newResetKey
            let ceilingChanged = abs(heightCeiling - newHeightCeiling) > 1

            if modelChanged {
                model?.onAppend = nil
                model?.onReset = nil
                model = newModel
                newModel.onAppend = { [weak self] chunk in self?.append(chunk) }
                newModel.onReset = { [weak self] in self?.rebuildContent(resetScroll: true) }
            }
            original = newOriginal
            bilingual = newBilingual
            placeholder = newPlaceholder
            resetKey = newResetKey
            heightCeiling = newHeightCeiling
            streamSettled = newStreamSettled

            if ceilingChanged { reachedHeightCeiling = false }
            if shouldRebuild {
                rebuildContent(resetScroll: shouldResetScroll)
            } else if ceilingChanged {
                scheduleHeightReport(force: true)
            }
        }

        private func rebuildContent(resetScroll: Bool) {
            guard let textView else { return }
            applyProjection()
            // A rebuild replaces the document (new run, 仅译文 ↔ 对照), so it may
            // legitimately be shorter than what was last reported.
            lastReportedHeight = 0
            reachedHeightCeiling = false
            allowsShrink = true
            if resetScroll { textView.scroll(.zero) }
            scheduleHeightReport(force: true)
            reportScrollState()
        }

        private func append(_ chunk: String) {
            guard !chunk.isEmpty else { return }
            // The projection (placeholder / 仅译文 / interleaved 对照) is
            // recomputed from `revealedText`, which already contains this flushed
            // chunk; extending the storage by the projection's suffix keeps the
            // append-only TextKit path for every mode. Height fitting is
            // throttled and stops after the scroll ceiling, while glyphs still
            // land immediately so the visible stream is never incomplete.
            let state = viewportState()
            let follow = !suppressFollow && state.overflowing && state.atBottom
            applyProjection()
            if follow { textView?.scrollToEndOfDocument(nil) }
            scheduleHeightReport(force: false)
            reportScrollState()
        }

        /// The full document for the current state: placeholder before the
        /// first chunk, raw translation in 仅译文, interleaved paragraph pairs
        /// in 对照 (plus the original's unpaired remainder once settled).
        private func projectedDocument() -> NSAttributedString {
            guard let model else { return NSAttributedString() }
            let blocks = PageModeLayout.textBlocks(
                original: original,
                translation: model.revealedText,
                bilingual: bilingual,
                placeholder: placeholder,
                settled: streamSettled
            )
            let output = NSMutableAttributedString()
            for (index, block) in blocks.enumerated() {
                // No trailing newline on the last block: the streaming tail
                // must extend in place, and a trailing separator would have to
                // be retracted on the next chunk (breaking the append path).
                let text = index < blocks.count - 1 ? block.text + "\n" : block.text
                output.append(NSAttributedString(string: text, attributes: attributes(for: block.role)))
            }
            return output
        }

        /// Sync the storage to the projection: append the suffix when the
        /// current content is a prefix of the target (the streaming steady
        /// state), otherwise replace wholesale (placeholder swap, trim edge
        /// cases, presentation changes).
        private func applyProjection() {
            guard let textView, let storage = textView.textStorage else { return }
            let target = projectedDocument()
            let targetString = target.string as NSString
            let currentLength = storage.length
            if targetString.length > currentLength,
               targetString.substring(to: currentLength) == storage.string {
                storage.append(target.attributedSubstring(
                    from: NSRange(location: currentLength, length: targetString.length - currentLength)
                ))
            } else if !targetString.isEqual(to: storage.string) {
                storage.setAttributedString(target)
            }
        }

        private func attributes(for role: PageModeLayout.TextBlock.Role) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            // 对照 pairs read as units: a source paragraph sits tight above its
            // translation (4), and the gap between pairs is wide (14).
            paragraph.paragraphSpacing = role == .source ? 4 : 14
            let color: NSColor = role == .translation ? .labelColor : .secondaryLabelColor
            return [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        }

        private func scheduleHeightReport(force: Bool) {
            if reachedHeightCeiling, !force { return }
            guard !heightReportScheduled else { return }
            heightReportScheduled = true
            // No throttle, same as the cards: the pacer already limits appends to
            // one per frame, and measuring stops for good once the page reaches
            // its ceiling (which a long document does almost immediately). A
            // delay here is simply the page lagging its own text.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightReportScheduled = false
                guard let handler = self.onContentHeightChange,
                      let textView = self.textView,
                      let height = documentHeight(of: textView) else { return }
                self.reachedHeightCeiling = height >= self.heightCeiling - 1
                // Within a run the document only grows (appends are the only
                // edit), so a measurement that comes back *shorter* is not the
                // content shrinking — it is TextKit 2 having dropped or
                // re-estimated layout outside the viewport, which is exactly
                // what happens while the view is scrolled hard. Trusting it
                // collapsed the card mid-run. Shrinking is allowed only where
                // the content genuinely can: a new run, or a width change that
                // rewraps the text.
                guard height > self.lastReportedHeight + 1 || self.allowsShrink else { return }
                self.allowsShrink = false
                self.lastReportedHeight = height
                handler(height)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

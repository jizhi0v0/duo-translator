import AppKit
import SwiftUI

/// Scroll view for a result body. Only overrides `scrollWheel` to keep scrolling
/// self-contained (no chaining to the outer list); it deliberately does NOT
/// touch `mouseDownCanMoveWindow` or replace the clip view — doing so broke text
/// selection inside the result.
private final class ResultScrollView: NSScrollView {
    /// Don't chain to the outer result list when there's nothing to scroll here,
    /// or when already at the top/bottom edge.
    override func scrollWheel(with event: NSEvent) {
        let contentHeight = documentView?.frame.height ?? 0
        let visibleHeight = contentView.bounds.height
        if contentHeight <= visibleHeight + 1 {
            return // nothing to scroll — swallow instead of lifting the outer list
        }
        let y = contentView.bounds.origin.y
        let maxY = contentHeight - visibleHeight
        let dy = event.scrollingDeltaY
        if (dy > 0 && y <= 0) || (dy < 0 && y >= maxY) {
            return // at the edge in this direction — don't chain
        }
        super.scrollWheel(with: event)
    }
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
    /// Ceiling for content-driven growth. Below it, `onContentHeightChange`
    /// tracks the text's natural height so the card can grow with the stream;
    /// once reached, reporting stops and the view scrolls internally instead.
    var heightCeiling: CGFloat = .greatestFiniteMagnitude
    /// Reports the text's natural content height (glyphs + insets), throttled,
    /// after each append/reset. Left nil by callers (like the thinking
    /// section) that just want a fixed min/max frame with no growth tracking.
    var onContentHeightChange: ((CGFloat) -> Void)?

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

        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
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
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.setup(
            textView: textView, attributes: attributes,
            onContentHeightChange: onContentHeightChange
        )
        context.coordinator.heightCeiling = heightCeiling
        context.coordinator.bindModel(model)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Each translation run hands the view a fresh StreamingTextModel; without
        // rebinding, only the first run would ever render.
        context.coordinator.onContentHeightChange = onContentHeightChange
        context.coordinator.heightCeiling = heightCeiling
        context.coordinator.bindModel(model)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var textView: NSTextView?
        private var attributes: [NSAttributedString.Key: Any] = [:]
        private weak var model: StreamingTextModel?
        var onContentHeightChange: ((CGFloat) -> Void)?
        var heightCeiling: CGFloat = .greatestFiniteMagnitude {
            didSet {
                guard abs(heightCeiling - oldValue) > 1 else { return }
                reachedHeightCeiling = false
                scheduleHeightReport(force: true)
            }
        }
        private var lastReportedHeight: CGFloat = 0
        private var reachedHeightCeiling = false
        private var heightReportScheduled = false
        private var forceNextHeightReport = false

        /// One-time wiring of the views.
        func setup(
            textView: NSTextView,
            attributes: [NSAttributedString.Key: Any],
            onContentHeightChange: ((CGFloat) -> Void)?
        ) {
            self.textView = textView
            self.attributes = attributes
            self.onContentHeightChange = onContentHeightChange
            // The text view is vertically resizable, so TextKit resizes it to fit
            // its content the instant a line wraps in (streaming) or the whole
            // document lands (one-shot). Observing that frame change — rather than
            // only polling after an append — is what lets the card track the text
            // in real time instead of trailing a throttle behind it.
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(textViewFrameChanged),
                name: NSView.frameDidChangeNotification, object: textView
            )
        }

        @objc private func textViewFrameChanged() {
            scheduleHeightReport(force: false)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

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
            if !newModel.fullText.isEmpty {
                append(newModel.fullText)
            }
            installCallbacks(on: newModel)
        }

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
            storage.beginEditing()
            storage.append(NSAttributedString(string: chunk, attributes: attributes))
            storage.endEditing()
            // A translation is read top-down, so don't follow the stream to the
            // bottom — leave the scroll position where it is (at the top for a
            // fresh run) so the reader starts from the beginning.
            //
            // No special path for one-shot vs. streaming engines: appending grows
            // the text view, `textViewFrameChanged` observes that, and the card
            // fits it. A one-shot fill (Apple, or any non-streaming engine) lands
            // its whole document in one append and expands to full height in a
            // single step exactly like a stream's final line — same code, no
            // engine-specific adaptation. This append-side report just covers the
            // first layout, where the frame notification may not have fired yet.
            scheduleHeightReport(force: false)
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
            lastReportedHeight = 0
            reachedHeightCeiling = false
            scheduleHeightReport(force: true)
        }

        /// Reported height is snapped up to a whole line (see
        /// `lineCeiledBodyHeight`), so the card grows in clean line-height steps
        /// rather than at raw (fractional) glyph heights that look stiff — and
        /// that snapping is what coalesces resizes: measurements between two
        /// line-crossings round to the same height and are dropped by the `> 1`
        /// guard below, so only an actual new line ever resizes the card.
        ///
        /// There is no throttle: the snap + `> 1` guard already collapse a burst
        /// of chunks into one resize per line, so the report only needs to hop to
        /// the next runloop (coalesced by `heightReportScheduled`) to stay out of
        /// the SwiftUI update phase. A throttle here would just leave the height a
        /// line behind the text. Measuring stops once the body hits its ceiling
        /// (`reachedHeightCeiling`), so the per-runloop cost stays bounded.
        private func scheduleHeightReport(force: Bool) {
            if reachedHeightCeiling, !force { return }
            forceNextHeightReport = forceNextHeightReport || force
            guard !heightReportScheduled else { return }
            heightReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightReportScheduled = false
                let forceReport = self.forceNextHeightReport
                self.forceNextHeightReport = false
                guard let handler = self.onContentHeightChange,
                      let textView = self.textView,
                      let lm = textView.textLayoutManager else { return }
                // An empty document (the "翻译中…" placeholder state) must report a
                // single line, never be measured: TextKit 2's usage bounds for an
                // empty container with unbounded height don't collapse to one line,
                // so measuring here would snap the placeholder card to the ceiling.
                // An empty document (the "翻译中…" placeholder state) must report a
                // single line, never be measured: TextKit 2's usage bounds for an
                // empty container with unbounded height don't collapse to one line,
                // so measuring here would snap the placeholder card to the ceiling.
                let raw: CGFloat
                if (textView.textStorage?.length ?? 0) == 0 {
                    raw = textView.textContainerInset.height * 2
                } else {
                    lm.ensureLayout(for: lm.documentRange)
                    raw = lm.usageBoundsForTextContainer.height
                        + textView.textContainerInset.height * 2
                }
                let height = PanelLayout.lineCeiledBodyHeight(atLeast: raw)
                self.reachedHeightCeiling = height >= self.heightCeiling - 1
                guard forceReport || abs(height - self.lastReportedHeight) > 1 else { return }
                self.lastReportedHeight = height
                handler(height)
            }
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
    var onContentHeightChange: ((CGFloat) -> Void)?

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
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.setup(textView: textView, onContentHeightChange: onContentHeightChange)
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
        private var forceNextHeightReport = false

        func setup(textView: NSTextView, onContentHeightChange: ((CGFloat) -> Void)?) {
            self.textView = textView
            self.onContentHeightChange = onContentHeightChange
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(frameChanged),
                name: NSView.frameDidChangeNotification, object: textView
            )
        }

        @objc private func frameChanged() {
            guard let width = textView?.bounds.width, abs(width - lastWidth) > 1 else { return }
            lastWidth = width
            reachedHeightCeiling = false
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
            let visiblePlaceholderChanged = placeholder != newPlaceholder && newModel.fullText.isEmpty
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
            lastReportedHeight = 0
            reachedHeightCeiling = false
            if resetScroll { textView.scroll(.zero) }
            scheduleHeightReport(force: true)
        }

        private func append(_ chunk: String) {
            guard !chunk.isEmpty else { return }
            // The projection (placeholder / 仅译文 / interleaved 对照) is
            // recomputed from `fullText`, which already contains this flushed
            // chunk; extending the storage by the projection's suffix keeps the
            // append-only TextKit path for every mode. Height fitting is
            // throttled and stops after the scroll ceiling, while glyphs still
            // land immediately so the visible stream is never incomplete.
            applyProjection()
            scheduleHeightReport(force: false)
        }

        /// The full document for the current state: placeholder before the
        /// first chunk, raw translation in 仅译文, interleaved paragraph pairs
        /// in 对照 (plus the original's unpaired remainder once settled).
        private func projectedDocument() -> NSAttributedString {
            guard let model else { return NSAttributedString() }
            let blocks = PageModeLayout.textBlocks(
                original: original,
                translation: model.fullText,
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
            forceNextHeightReport = forceNextHeightReport || force
            guard !heightReportScheduled else { return }
            heightReportScheduled = true
            let delay: TimeInterval = force ? 0 : 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.heightReportScheduled = false
                let forceReport = self.forceNextHeightReport
                self.forceNextHeightReport = false
                guard let handler = self.onContentHeightChange,
                      let textView = self.textView,
                      let lm = textView.textLayoutManager else { return }
                lm.ensureLayout(for: lm.documentRange)
                let height = lm.usageBoundsForTextContainer.height
                    + textView.textContainerInset.height * 2
                self.reachedHeightCeiling = height >= self.heightCeiling - 1
                guard forceReport || abs(height - self.lastReportedHeight) > 1 else { return }
                self.lastReportedHeight = height
                handler(height)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

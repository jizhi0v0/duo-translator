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
            scrollView: scrollView,
            textView: textView,
            attributes: attributes,
            onContentHeightChange: onContentHeightChange
        )
        context.coordinator.bindModel(model)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onContentHeightChange = onContentHeightChange
        // Each translation run hands the view a fresh StreamingTextModel; without
        // rebinding, only the first run would ever render.
        context.coordinator.bindModel(model)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var attributes: [NSAttributedString.Key: Any] = [:]
        var onContentHeightChange: ((CGFloat) -> Void)?
        private var lastReportedHeight: CGFloat = 0
        private weak var model: StreamingTextModel?

        /// One-time wiring of the views and the width observer.
        func setup(
            scrollView: NSScrollView,
            textView: NSTextView,
            attributes: [NSAttributedString.Key: Any],
            onContentHeightChange: ((CGFloat) -> Void)?
        ) {
            self.scrollView = scrollView
            self.textView = textView
            self.attributes = attributes
            self.onContentHeightChange = onContentHeightChange

            // Re-measure when the view's width changes. Text height depends on
            // the wrap width, and SwiftUI sizes the NSView to its real width
            // *after* makeNSView/bindModel run — so the first measurement can
            // happen at width ~0 (everything wraps, height explodes). Reporting
            // again on the frame change corrects it to the true height.
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textViewFrameChanged(_:)),
                name: NSView.frameDidChangeNotification,
                object: textView
            )
        }

        @objc private func textViewFrameChanged(_ notification: Notification) {
            reportHeight()
        }

        /// Attach to the run's text model. Called on every SwiftUI update; each
        /// translation run supplies a new model, so we detach the old one, clear
        /// the view, and replay whatever the new model already buffered.
        func bindModel(_ newModel: StreamingTextModel) {
            guard newModel !== model else { return }
            model?.onAppend = nil
            model?.onReset = nil
            model = newModel

            resetText()
            if !newModel.fullText.isEmpty {
                append(newModel.fullText)
            }
            newModel.onAppend = { [weak self] chunk in
                self?.append(chunk)
            }
            newModel.onReset = { [weak self] in
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
            reportHeight()
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
            reportHeight()
        }

        private func reportHeight() {
            guard let handler = onContentHeightChange, let textView else { return }
            let height = contentHeight(of: textView)
            if abs(height - lastReportedHeight) > 1 {
                lastReportedHeight = height
                handler(height)
            }
        }

        /// The real laid-out height of the text at the current container width.
        ///
        /// `documentView.frame.height` can't be used: an NSTextView inflates to
        /// fill its enclosing clip view, so once the frame grows it never
        /// reports back down (a latch that left tall blank gaps below short
        /// translations). The TextKit 2 layout manager's usage bounds reflect
        /// only the glyphs, so the height tracks the text both up and down.
        private func contentHeight(of textView: NSTextView) -> CGFloat {
            guard let layoutManager = textView.textLayoutManager else {
                return textView.intrinsicContentSize.height
            }
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            let used = layoutManager.usageBoundsForTextContainer.height
            return used + textView.textContainerInset.height * 2
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

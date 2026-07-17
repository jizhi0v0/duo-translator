import AppKit
import SwiftUI

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

        let scrollView = NSScrollView()
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
        private var isFollowing = true
        var onContentHeightChange: ((CGFloat) -> Void)?
        private var lastReportedHeight: CGFloat = 0
        private weak var model: StreamingTextModel?

        /// One-time wiring of the views and scroll observer.
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

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userScrolled(_:)),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
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
            if isFollowing {
                textView.scrollToEndOfDocument(nil)
            }
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
            isFollowing = true
            lastReportedHeight = 0
            reportHeight()
        }

        @objc private func userScrolled(_ notification: Notification) {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let visibleMaxY = scrollView.contentView.bounds.maxY
            let bottom = documentView.frame.height
            isFollowing = visibleMaxY >= bottom - 24
        }

        private func reportHeight() {
            guard let handler = onContentHeightChange,
                  let documentView = scrollView?.documentView else { return }
            // TextKit 2 keeps this an estimate until layout catches up — good
            // enough for panel growth, and free to read.
            let height = documentView.frame.height
            if abs(height - lastReportedHeight) > 1 {
                lastReportedHeight = height
                handler(height)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

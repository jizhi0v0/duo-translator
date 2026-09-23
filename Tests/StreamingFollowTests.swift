import AppKit
import XCTest
@testable import DuoTranslator

/// Follow-the-stream must be a reader decision. A scroll view whose short text
/// still fits reports "at the bottom" for any offset, and a bounds change that
/// is not the reader (the window-drag scroll restore) must not turn that into
/// "follow": once the text overflows, every new wrapped line would then pin the
/// viewport to the end while the card's height catches up a frame later — the
/// body flickers between clipped-at-top and back.
@MainActor
final class StreamingFollowTests: XCTestCase {
    private func makeReader() -> (StreamingTextView.Coordinator, NSScrollView, StreamingTextModel) {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 0)

        let coordinator = StreamingTextView.Coordinator()
        coordinator.setup(textView: textView, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let model = StreamingTextModel()
        coordinator.bindModel(model)
        return (coordinator, scrollView, model)
    }

    func testNonReaderScrollOnShortTextDoesNotEngageFollow() {
        let (coordinator, scrollView, model) = makeReader()
        defer { withExtendedLifetime(coordinator) {} }
        model.append("短")
        model.finish()
        // What the drag's scroll restore does: a programmatic clip scroll that
        // is not ours and changes no geometry.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0.25))
        scrollView.contentView.scroll(to: .zero)
        XCTAssertFalse(model.followsStream, "fitting text: there is no bottom to have reached")

        model.append(String(repeating: "检测有效，但返回的文本为空。", count: 20))
        model.finish()
        XCTAssertLessThan(
            scrollView.contentView.bounds.origin.y, 1,
            "not following: the reading position stays at the top"
        )
    }
}

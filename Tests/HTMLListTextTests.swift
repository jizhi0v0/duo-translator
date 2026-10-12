import XCTest
@testable import DuoTranslator

final class HTMLListTextTests: XCTestCase {
    func testNoListReturnsNil() {
        XCTAssertNil(HTMLListText.text(fromHTML: "<p>Just a paragraph.</p><p>Another.</p>"))
    }

    /// Shape of what Claude desktop puts on the pasteboard for a reply.
    func testClaudeReplyKeepsHeadingsAndListMarkers() {
        let html = """
        <meta charset='utf-8'><div style="display: flow-root;"><div role="article"><div><div>\
        <h2>What it shows</h2>
        <ol>
        <li><p><strong>No later knowledge:</strong> all 9 runs said unknown.</p></li>
        <li><p><strong>Effort makes no difference:</strong> <code>claude-opus-5</code> matched.</p></li>
        </ol>
        <h2>Test limitations</h2>
        <ul>
        <li><p><strong>Low sensitivity:</strong> weak evidence.</p></li>
        <li><p>q5 and q6 are contaminated.</p></li>
        </ul>
        <p><strong>Overall:</strong> all agree.</p>
        </div></div></div></div>
        """
        XCTAssertEqual(HTMLListText.text(fromHTML: html), """
        What it shows

        1. No later knowledge: all 9 runs said unknown.
        2. Effort makes no difference: claude-opus-5 matched.

        Test limitations

        • Low sensitivity: weak evidence.
        • q5 and q6 are contaminated.

        Overall: all agree.
        """)
    }

    func testOrderedListHonorsStart() {
        XCTAssertEqual(
            HTMLListText.text(fromHTML: #"<ol start="3"><li>c</li><li>d</li></ol>"#),
            "3. c\n4. d"
        )
    }

    func testNestedListsIndent() {
        let html = "<ul><li>top<ul><li>child<ol><li>deep</li></ol></li></ul></li><li>next</li></ul>"
        XCTAssertEqual(HTMLListText.text(fromHTML: html), "• top\n  • child\n    1. deep\n• next")
    }

    func testMultiParagraphListItemStaysTight() {
        let html = "<ol><li><p>first para</p><p>second para</p></li><li><p>two</p></li></ol>"
        XCTAssertEqual(HTMLListText.text(fromHTML: html), "1. first para\nsecond para\n2. two")
    }

    func testPreKeepsWhitespaceAndBreaks() {
        let html = "<ul><li>run:</li></ul><pre><code>let x = 1\n    let y = 2</code></pre><p>done</p>"
        XCTAssertEqual(HTMLListText.text(fromHTML: html), "• run:\n\nlet x = 1\n    let y = 2\n\ndone")
    }

    func testInlineWhitespaceCollapsesButSeparatesWords() {
        let html = "<ul><li>  <b>bold</b>\n   tail  <i>it</i>\n</li></ul>"
        XCTAssertEqual(HTMLListText.text(fromHTML: html), "• bold tail it")
    }

    func testBrBreaksLine() {
        XCTAssertEqual(HTMLListText.text(fromHTML: "<ul><li>a<br>b</li></ul>"), "• a\nb")
    }

    func testEntitiesDecoded() {
        let html = "<ul><li>a &amp; b &lt;c&gt; &#8220;q&#x201D; caf&eacute;</li></ul>"
        // Unknown named entities are left as written.
        XCTAssertEqual(HTMLListText.text(fromHTML: html), "• a & b <c> “q” caf&eacute;")
    }

    func testScriptStyleAndCommentsSkipped() {
        let html = "<style>li{color:red}</style><!-- <li>no</li> --><ul><li>yes<script>x<1</script></li></ul>"
        XCTAssertEqual(HTMLListText.text(fromHTML: html), "• yes")
    }
}

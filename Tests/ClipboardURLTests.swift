import XCTest
@testable import DuoTranslator

@MainActor
final class ClipboardURLTests: XCTestCase {

    func testAcceptsHTTPS() {
        XCTAssertEqual(ClipboardURL.parse("https://example.com/article")?.host, "example.com")
    }

    func testAcceptsHTTP() {
        XCTAssertEqual(ClipboardURL.parse("http://example.com")?.scheme, "http")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertNotNil(ClipboardURL.parse("  https://example.com/x  \n"))
    }

    func testRejectsPlainText() {
        XCTAssertNil(ClipboardURL.parse("just some copied text"))
    }

    func testRejectsSentenceContainingURL() {
        // A URL has no interior whitespace; a sentence that merely mentions a
        // link is not a link.
        XCTAssertNil(ClipboardURL.parse("see https://example.com for more"))
    }

    func testRejectsNonWebScheme() {
        XCTAssertNil(ClipboardURL.parse("ftp://example.com/file"))
        XCTAssertNil(ClipboardURL.parse("file:///Users/x/a.txt"))
        XCTAssertNil(ClipboardURL.parse("mailto:a@b.com"))
    }

    func testRejectsSchemeWithoutHost() {
        XCTAssertNil(ClipboardURL.parse("https://"))
    }

    func testRejectsBareWord() {
        XCTAssertNil(ClipboardURL.parse("example.com"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(ClipboardURL.parse("   "))
    }
}

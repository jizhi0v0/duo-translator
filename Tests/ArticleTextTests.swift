import XCTest
@testable import DuoTranslator

final class ArticleTextTests: XCTestCase {

    func testTrimsLeadingAndTrailingBlankLines() {
        XCTAssertEqual(ArticleText.normalize("\n\n  A\n\nB \n\n"), "A\n\nB")
    }

    func testCollapsesRunsOfBlankLinesToOne() {
        XCTAssertEqual(ArticleText.normalize("A\n\n\n\nB"), "A\n\nB")
    }

    func testKeepsSingleNewlineParagraphs() {
        // The extraction joins block elements with single newlines; those are the
        // paragraph units page mode pairs on and must survive normalization.
        XCTAssertEqual(ArticleText.normalize("p1\np2\np3"), "p1\np2\np3")
    }

    func testTrimsPerLineWhitespace() {
        // Single newline (no blank line between) stays a single-newline join.
        XCTAssertEqual(ArticleText.normalize("  hello  \n\t world \t"), "hello\nworld")
    }

    func testNormalizesCRLF() {
        XCTAssertEqual(ArticleText.normalize("A\r\n\r\nB"), "A\n\nB")
    }

    func testEmptyInputIsEmpty() {
        XCTAssertEqual(ArticleText.normalize("   \n\n  "), "")
    }

    // MARK: firstHeading

    func testFirstHeadingSkipsNavLines() {
        let md = "Home\nSign In\n\n# 深圳地铁被人推倒在地的后续\n\n正文…"
        XCTAssertEqual(ArticleText.firstHeading(md), "深圳地铁被人推倒在地的后续")
    }

    func testFirstHeadingNilWhenNoHeading() {
        XCTAssertNil(ArticleText.firstHeading("just body text\nmore text"))
    }

    func testFirstHeadingIgnoresDeeperHeadings() {
        // Only H1 ("# ") is the title; "## " subsections don't count.
        XCTAssertEqual(ArticleText.firstHeading("## sub\n# Real Title\ntext"), "Real Title")
    }

    // MARK: articleBody

    func testArticleBodyTrimsLeadingNav() {
        let raw = "Home\nSign In\nAdvertisement\n# 标题\n\n正文第一段\n正文第二段"
        XCTAssertEqual(ArticleText.articleBody(raw), "# 标题\n\n正文第一段\n正文第二段")
    }

    func testArticleBodyKeepsAllWhenNoHeading() {
        let raw = "just body\nno heading here"
        XCTAssertEqual(ArticleText.articleBody(raw), raw)
    }
}

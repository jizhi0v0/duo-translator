import XCTest
@testable import DuoTranslator

final class AppleTranslationOutputTests: XCTestCase {

    // MARK: paragraphBlocks

    func testSingleParagraphIsOneBlock() {
        XCTAssertEqual(AppleTranslationOutput.paragraphBlocks("Hello world."),
                       ["Hello world."])
    }

    func testBlankLineSplitsBlocks() {
        XCTAssertEqual(AppleTranslationOutput.paragraphBlocks("A\n\nB"),
                       ["A", "B"])
    }

    func testMultipleBlankLinesAndSpacesStillOneBoundary() {
        XCTAssertEqual(AppleTranslationOutput.paragraphBlocks("A\n\n \n\t\nB"),
                       ["A", "B"])
    }

    func testSingleNewlineStaysInsideBlock() {
        XCTAssertEqual(AppleTranslationOutput.paragraphBlocks("line1\nline2\n\npara2"),
                       ["line1\nline2", "para2"])
    }

    func testLeadingAndTrailingBlankLinesIgnored() {
        XCTAssertEqual(AppleTranslationOutput.paragraphBlocks("\n\nA\n\n"),
                       ["A"])
    }

    func testWhitespaceOnlyTextHasNoBlocks() {
        XCTAssertEqual(AppleTranslationOutput.paragraphBlocks("  \n \n"), [])
    }

    // MARK: normalizedBlock

    func testNormalizeTrimsEdges() {
        XCTAssertEqual(AppleTranslationOutput.normalizedBlock("\n译文。\n"), "译文。")
    }

    func testNormalizeCollapsesInventedBlankLinesToSingleNewline() {
        // Apple sometimes returns sentence fragments separated by blank lines
        // for a source block that had none.
        XCTAssertEqual(AppleTranslationOutput.normalizedBlock("句一。\n\n句二。\n\n\n句三。"),
                       "句一。\n句二。\n句三。")
    }

    func testNormalizeKeepsSingleNewlines() {
        XCTAssertEqual(AppleTranslationOutput.normalizedBlock("行一\n行二"),
                       "行一\n行二")
    }

    func testNormalizeCollapsesBlankLinesWithSpaces() {
        XCTAssertEqual(AppleTranslationOutput.normalizedBlock("句一。\n \t\n句二。"),
                       "句一。\n句二。")
    }

    // MARK: join

    func testJoinUsesExactlyOneBlankLine() {
        XCTAssertEqual(AppleTranslationOutput.join(["段一。", "段二。"]),
                       "段一。\n\n段二。")
    }

    func testJoinDropsEmptySegmentsAndNormalizesEach() {
        XCTAssertEqual(AppleTranslationOutput.join(["段一。\n\n续。", "", " \n", "段二。\n"]),
                       "段一。\n续。\n\n段二。")
    }

    // MARK: end-to-end shape

    func testFragmentedResponseCollapsesToSourceStructure() {
        let source = "First sentence. Second sentence.\n\nAnother paragraph here."
        let blocks = AppleTranslationOutput.paragraphBlocks(source)
        XCTAssertEqual(blocks.count, 2)
        // Simulate Apple fragmenting each block into blank-line-separated
        // sentences; the join must restore two tight paragraphs.
        let fragmented = ["第一句。\n\n第二句。\n", "\n另一段。"]
        XCTAssertEqual(AppleTranslationOutput.join(fragmented),
                       "第一句。\n第二句。\n\n另一段。")
    }
}

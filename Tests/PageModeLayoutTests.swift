import XCTest
@testable import DuoTranslator

/// Covers page mode's pure rule: which provider is shown as the selection or the
/// run set changes.
final class PageModeLayoutTests: XCTestCase {

    // MARK: - resolvedProvider (selection fallback)

    func testResolvedProviderKeepsValidSelection() {
        XCTAssertEqual(
            PageModeLayout.resolvedProvider(ids: ["a", "b", "c"], selected: "b"), "b")
    }

    func testResolvedProviderFallsBackToFirstWhenSelectionMissing() {
        XCTAssertEqual(
            PageModeLayout.resolvedProvider(ids: ["a", "b"], selected: "gone"), "a")
    }

    func testResolvedProviderFallsBackToFirstWhenNil() {
        XCTAssertEqual(PageModeLayout.resolvedProvider(ids: ["a", "b"], selected: nil), "a")
    }

    func testResolvedProviderNilWhenNoRuns() {
        XCTAssertNil(PageModeLayout.resolvedProvider(ids: [], selected: "a"))
        XCTAssertNil(PageModeLayout.resolvedProvider(ids: [], selected: nil))
    }

    // MARK: - paragraphUnits (the units 对照 pairs by index)

    func testParagraphUnitsSplitsAndTrims() {
        XCTAssertEqual(PageModeLayout.paragraphUnits("a\nb\nc"), ["a", "b", "c"])
        XCTAssertEqual(PageModeLayout.paragraphUnits("  hello  "), ["hello"])
    }

    func testParagraphUnitsDropsBlankLines() {
        // Blank lines are spacing, not content — dropped so both sides stay in
        // step (e.g. Apple separates paragraphs with an extra blank line).
        XCTAssertEqual(PageModeLayout.paragraphUnits("a\n\nb\n \nc"), ["a", "b", "c"])
    }

    func testParagraphUnitsEmptyForBlankInput() {
        XCTAssertEqual(PageModeLayout.paragraphUnits(""), [])
        XCTAssertEqual(PageModeLayout.paragraphUnits("\n  \n"), [])
    }
}

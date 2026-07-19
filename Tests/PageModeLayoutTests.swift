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
}

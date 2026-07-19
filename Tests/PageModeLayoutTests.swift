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

    // MARK: - interleaved 对照 blocks

    func testBilingualBlocksInterleaveParagraphPairs() {
        let blocks = PageModeLayout.textBlocks(
            original: "第一段\n第二段",
            translation: "first paragraph\nsecond paragraph",
            bilingual: true,
            placeholder: "loading"
        )
        XCTAssertEqual(blocks, [
            .init(text: "第一段", role: .source),
            .init(text: "first paragraph", role: .translation),
            .init(text: "第二段", role: .source),
            .init(text: "second paragraph", role: .translation),
        ])
    }

    func testBilingualBlocksPreserveBothSidesWithoutParagraphTruncation() {
        // One source paragraph, three translated ones (engine reformatted):
        // extra translation paragraphs must still show; once settled, an
        // original with MORE paragraphs than the translation keeps its
        // unpaired remainder too.
        let blocks = PageModeLayout.textBlocks(
            original: "原文只有一个逻辑段落",
            translation: "first\n\nsecond\nthird",
            bilingual: true,
            placeholder: "loading"
        )
        XCTAssertEqual(blocks, [
            .init(text: "原文只有一个逻辑段落", role: .source),
            .init(text: "first", role: .translation),
            .init(text: "second", role: .translation),
            .init(text: "third", role: .translation),
        ])

        let merged = PageModeLayout.textBlocks(
            original: "甲\n乙\n丙",
            translation: "everything merged into one",
            bilingual: true,
            placeholder: "loading",
            settled: true
        )
        XCTAssertEqual(merged, [
            .init(text: "甲", role: .source),
            .init(text: "everything merged into one", role: .translation),
            .init(text: "乙", role: .source),
            .init(text: "丙", role: .source),
        ])
    }

    func testFlatSourceFallsBackToSentencePairing() {
        // 划词 capture often strips newlines: the source arrives as one flat
        // paragraph. 对照 must still interleave — sentence by sentence.
        let blocks = PageModeLayout.textBlocks(
            original: "第一句。第二句！",
            translation: "First sentence. Second sentence!",
            bilingual: true,
            placeholder: "loading"
        )
        XCTAssertEqual(blocks, [
            .init(text: "第一句。", role: .source),
            .init(text: "First sentence.", role: .translation),
            .init(text: "第二句！", role: .source),
            .init(text: "Second sentence!", role: .translation),
        ])
    }

    func testSentenceUnitsKeepDecimalsAndVersionsIntact() {
        XCTAssertEqual(
            PageModeLayout.sentenceUnits("It took 1.5s to run v3.2 of the tool. Then it stopped."),
            ["It took 1.5s to run v3.2 of the tool.", "Then it stopped."]
        )
    }

    func testBilingualStreamingHoldsUnpairedSourceUntilSettled() {
        // Mid-stream (settled: false) the untranslated remainder of the
        // original stays hidden, so the projection only ever extends as the
        // translation appends — the reader's append-only invariant.
        let streaming = PageModeLayout.textBlocks(
            original: "第一段\n第二段\n第三段",
            translation: "first paragraph",
            bilingual: true,
            placeholder: "loading",
            settled: false
        )
        XCTAssertEqual(streaming, [
            .init(text: "第一段", role: .source),
            .init(text: "first paragraph", role: .translation),
        ])
    }

    func testTranslationOnlyBlockPreservesExactText() {
        let translation = "a\n\nb\n \nc"
        XCTAssertEqual(PageModeLayout.textBlocks(
            original: "source",
            translation: translation,
            bilingual: false,
            placeholder: "loading"
        ), [.init(text: translation, role: .translation)])
    }

    func testEmptyTranslationShowsOnlyCompactPlaceholder() {
        XCTAssertEqual(PageModeLayout.textBlocks(
            original: "long source",
            translation: "",
            bilingual: true,
            placeholder: "翻译中…"
        ), [.init(text: "翻译中…", role: .placeholder)])
    }
}

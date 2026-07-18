import XCTest
@testable import DuoTranslator

final class CapturedTextSanitizerTests: XCTestCase {
    // MARK: - containsReplacementCharacter

    func testDetectsReplacementCharacter() {
        XCTAssertTrue(CapturedTextSanitizer.containsReplacementCharacter("ま\u{FFFD}看"))
        XCTAssertFalse(CapturedTextSanitizer.containsReplacementCharacter("ま看"))
        XCTAssertFalse(CapturedTextSanitizer.containsReplacementCharacter(""))
    }

    // MARK: - sanitized

    func testSanitizedRemovesReplacementCharacter() {
        XCTAssertEqual(CapturedTextSanitizer.sanitized("ま\u{FFFD}看"), "ま看")
    }

    func testSanitizedRemovesMultipleReplacementCharacters() {
        XCTAssertEqual(CapturedTextSanitizer.sanitized("\u{FFFD}\u{FFFD}早く\u{FFFD}"), "早く")
    }

    func testSanitizedReturnsEmptyWhenOnlyReplacementCharacters() {
        XCTAssertEqual(CapturedTextSanitizer.sanitized("\u{FFFD}"), "")
    }

    func testSanitizedLeavesCleanTextUntouched() {
        let clean = "café 早く見て 😀 e\u{301}"
        XCTAssertEqual(CapturedTextSanitizer.sanitized(clean), clean)
    }

    // MARK: - alignedRange

    func testAlignedRangeKeepsRangeOnCharacterBoundaries() {
        XCTAssertEqual(
            CapturedTextSanitizer.alignedRange(NSRange(location: 1, length: 1), in: "abc"),
            NSRange(location: 1, length: 1)
        )
    }

    func testAlignedRangeWidensRangeInsideSurrogatePair() {
        // "a😀b" in UTF-16: a=0, 😀=1...2, b=3.
        XCTAssertEqual(
            CapturedTextSanitizer.alignedRange(NSRange(location: 1, length: 1), in: "a😀b"),
            NSRange(location: 1, length: 2)
        )
    }

    func testAlignedRangeWidensEndThatSplitsSurrogatePair() {
        XCTAssertEqual(
            CapturedTextSanitizer.alignedRange(NSRange(location: 0, length: 2), in: "a😀b"),
            NSRange(location: 0, length: 3)
        )
    }

    func testAlignedRangeWidensStartThatSplitsSurrogatePair() {
        XCTAssertEqual(
            CapturedTextSanitizer.alignedRange(NSRange(location: 2, length: 2), in: "a😀b"),
            NSRange(location: 1, length: 3)
        )
    }

    func testAlignedRangeCoversCombiningSequence() {
        // "e" + U+0301 is one composed character sequence occupying (0, 2).
        XCTAssertEqual(
            CapturedTextSanitizer.alignedRange(NSRange(location: 0, length: 1), in: "e\u{301}x"),
            NSRange(location: 0, length: 2)
        )
    }

    func testAlignedRangeClampsOverlongLength() {
        XCTAssertEqual(
            CapturedTextSanitizer.alignedRange(NSRange(location: 1, length: 99), in: "abc"),
            NSRange(location: 1, length: 2)
        )
    }

    func testAlignedRangePreservesZeroLength() {
        XCTAssertEqual(
            CapturedTextSanitizer.alignedRange(NSRange(location: 2, length: 0), in: "abc"),
            NSRange(location: 2, length: 0)
        )
    }

    func testAlignedRangeRejectsOutOfBoundsLocation() {
        XCTAssertNil(CapturedTextSanitizer.alignedRange(NSRange(location: 4, length: 1), in: "abc"))
        XCTAssertNil(CapturedTextSanitizer.alignedRange(NSRange(location: -1, length: 1), in: "abc"))
    }
}

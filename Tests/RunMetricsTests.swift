import XCTest
@testable import DuoTranslator

final class RunMetricsTests: XCTestCase {

    func testThroughputMeasuredOverDecodeWindowExcludingTTFT() {
        // 900 completion tokens, 1s to first token, 10s total → 9s decode
        // window → 100 tok/s. Using the full 10s would understate it at 90.
        let m = RunMetrics.make(
            total: 10, ttft: 1, outputChars: 3000,
            promptTokens: 50, completionTokens: 900, totalTokens: 950
        )
        XCTAssertEqual(m.generation, 9, accuracy: 0.0001)
        XCTAssertEqual(m.tokensPerSecond ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(m.charsPerSecond ?? 0, 3000.0 / 9.0, accuracy: 0.0001)
    }

    func testFallsBackToCharsPerSecondWhenNoCompletionTokens() {
        let m = RunMetrics.make(
            total: 5, ttft: 1, outputChars: 400,
            promptTokens: nil, completionTokens: nil, totalTokens: nil
        )
        XCTAssertNil(m.tokensPerSecond)
        XCTAssertEqual(m.charsPerSecond ?? 0, 100, accuracy: 0.0001) // 400 / 4s
        XCTAssertFalse(m.tooltip.contains("tok/s"))
        XCTAssertTrue(m.tooltip.contains("字/s"))
    }

    func testNoFirstTokenUsesFullRunAsDecodeWindow() {
        let m = RunMetrics.make(
            total: 8, ttft: nil, outputChars: 80,
            promptTokens: nil, completionTokens: nil, totalTokens: nil
        )
        XCTAssertEqual(m.generation, 8, accuracy: 0.0001)
        XCTAssertEqual(m.charsPerSecond ?? 0, 10, accuracy: 0.0001)
        XCTAssertFalse(m.tooltip.contains("首 Token"), "no TTFT line when no token arrived")
    }

    func testInstantResponseDoesNotDivideByZero() {
        // total == ttft → zero decode window; rates must be nil, not inf/NaN.
        let m = RunMetrics.make(
            total: 2, ttft: 2, outputChars: 10,
            promptTokens: 1, completionTokens: 5, totalTokens: 6
        )
        XCTAssertEqual(m.generation, 0, accuracy: 0.0001)
        XCTAssertNil(m.tokensPerSecond)
        XCTAssertNil(m.charsPerSecond)
    }

    func testTooltipCarriesAllLLMLines() {
        let m = RunMetrics.make(
            total: 3.14, ttft: 0.42, outputChars: 128,
            promptTokens: 156, completionTokens: 892, totalTokens: 1048
        )
        let t = m.tooltip
        XCTAssertTrue(t.contains("首 Token 0.42s"))
        XCTAssertTrue(t.contains("总耗时 3.1s"))
        XCTAssertTrue(t.contains("tok/s"))
        XCTAssertTrue(t.contains("156→892"))
        XCTAssertTrue(t.contains("（共 1048）"))
    }
}

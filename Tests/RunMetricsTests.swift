import XCTest
@testable import DuoTranslator

final class RunMetricsTests: XCTestCase {

    func testThroughputMeasuredOverDecodeWindowExcludingTTFT() {
        // 900 completion tokens, 1s to first token, 10s total → 9s decode
        // window → 100 tok/s. Using the full 10s would understate it at 90.
        let m = RunMetrics.make(
            total: 10, ttft: 1, outputChars: 3000,
            usage: TokenUsage(prompt: 50, completion: 900, total: 950)
        )
        XCTAssertEqual(m.generation, 9, accuracy: 0.0001)
        XCTAssertEqual(m.tokensPerSecond ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(m.charsPerSecond ?? 0, 3000.0 / 9.0, accuracy: 0.0001)
    }

    func testFallsBackToCharsPerSecondWhenNoCompletionTokens() {
        let m = RunMetrics.make(
            total: 5, ttft: 1, outputChars: 400,
            usage: TokenUsage(prompt: nil, completion: nil, total: nil)
        )
        XCTAssertNil(m.tokensPerSecond)
        XCTAssertEqual(m.charsPerSecond ?? 0, 100, accuracy: 0.0001) // 400 / 4s
        XCTAssertFalse(m.tooltip.contains("tok/s"))
        XCTAssertTrue(m.tooltip.contains("字/s"))
    }

    func testNoFirstTokenUsesFullRunAsDecodeWindow() {
        let m = RunMetrics.make(
            total: 8, ttft: nil, outputChars: 80,
            usage: TokenUsage(prompt: nil, completion: nil, total: nil)
        )
        XCTAssertEqual(m.generation, 8, accuracy: 0.0001)
        XCTAssertEqual(m.charsPerSecond ?? 0, 10, accuracy: 0.0001)
        XCTAssertFalse(m.tooltip.contains("首 Token"), "no TTFT line when no token arrived")
    }

    func testInstantResponseDoesNotDivideByZero() {
        // total == ttft → zero decode window; rates must be nil, not inf/NaN.
        let m = RunMetrics.make(
            total: 2, ttft: 2, outputChars: 10,
            usage: TokenUsage(prompt: 1, completion: 5, total: 6)
        )
        XCTAssertEqual(m.generation, 0, accuracy: 0.0001)
        XCTAssertNil(m.tokensPerSecond)
        XCTAssertNil(m.charsPerSecond)
    }

    func testTooltipCarriesAllLLMLines() {
        let m = RunMetrics.make(
            total: 3.14, ttft: 0.42, outputChars: 128,
            usage: TokenUsage(prompt: 156, completion: 892, total: 1048)
        )
        let t = m.tooltip
        XCTAssertTrue(t.contains("首 Token 0.42s"))
        XCTAssertTrue(t.contains("总耗时 3.1s"))
        XCTAssertTrue(t.contains("tok/s"))
        XCTAssertTrue(t.contains("156→892"))
        XCTAssertTrue(t.contains("（共 1048）"))
    }

    // MARK: - Cost

    func testCostSplitsInputAndOutputRates() {
        let pricing = EnginePricing(inputPerMillion: 3, outputPerMillion: 15)
        let usage = TokenUsage(prompt: 1_000_000, completion: 1_000_000, total: 2_000_000)
        XCTAssertEqual(pricing.cost(of: usage) ?? 0, 18, accuracy: 0.0001)
    }

    /// Providers report cached tokens as a *subset* of the prompt count, so a
    /// cache hit must move tokens onto the cheaper rate — not add to the bill.
    func testCachedPromptTokensAreBilledOnceAtTheCacheRate() {
        let pricing = EnginePricing(
            inputPerMillion: 3, outputPerMillion: 15, cachedInputPerMillion: 0.3
        )
        let usage = TokenUsage(
            prompt: 1_000_000, completion: 0, total: 1_000_000, cachedPrompt: 900_000
        )
        // 100k at full price + 900k at a tenth = 0.3 + 0.27
        XCTAssertEqual(pricing.cost(of: usage) ?? 0, 0.57, accuracy: 0.0001)
    }

    func testNoPricesMeansNoCostRatherThanZero() {
        var profile = EngineProfile.makeDefault(kind: .openAICompat)
        profile.inputPricePerMTok = 0
        profile.outputPricePerMTok = 0
        XCTAssertNil(EnginePricing(profile: profile))

        let m = RunMetrics.make(
            total: 2, ttft: 0.5, outputChars: 10,
            usage: TokenUsage(prompt: 10, completion: 10, total: 20)
        )
        XCTAssertNil(m.cost)
        XCTAssertNil(m.costDisplay)
    }

    /// A translation usually costs a fraction of a cent; rounding to two
    /// decimals would report every run as 0.00.
    func testSubCentCostKeepsEnoughDigits() {
        let m = RunMetrics.make(
            total: 2, ttft: 0.5, outputChars: 10,
            usage: TokenUsage(prompt: 500, completion: 300, total: 800),
            pricing: EnginePricing(inputPerMillion: 3, outputPerMillion: 15)
        )
        XCTAssertEqual(m.costDisplay, "0.0060")
    }

    // MARK: - Reasoning, cache, stalls, routing

    func testReasoningShareOfOutput() {
        let m = RunMetrics.make(
            total: 10, ttft: 1, outputChars: 40,
            usage: TokenUsage(prompt: 20, completion: 1000, total: 1020, reasoning: 800)
        )
        XCTAssertEqual(m.reasoningDisplay, "800（占输出 80%）")
    }

    func testCacheDisplayOnlyWhenSomethingWasCached() {
        let none = RunMetrics.make(
            total: 1, ttft: 0.2, outputChars: 5,
            usage: TokenUsage(prompt: 100, completion: 10, total: 110, cachedPrompt: 0)
        )
        XCTAssertNil(none.cacheDisplay, "a zero hit is not worth a row")

        let hit = RunMetrics.make(
            total: 1, ttft: 0.2, outputChars: 5,
            usage: TokenUsage(prompt: 100, completion: 10, total: 110, cachedPrompt: 25)
        )
        XCTAssertEqual(hit.cacheDisplay, "25（25%）")
    }

    func testOnlyRealStallsAreReported() {
        let jitter = RunMetrics.make(
            total: 5, ttft: 0.5, outputChars: 100, chunkGaps: [0.02, 0.05, 0.11]
        )
        XCTAssertNil(jitter.stallDisplay, "ordinary token jitter is not a stall")

        let stalled = RunMetrics.make(
            total: 5, ttft: 0.5, outputChars: 100, chunkGaps: [0.02, 1.8, 0.05]
        )
        XCTAssertEqual(stalled.longestChunkGap, 1.8)
        XCTAssertEqual(stalled.stallDisplay, "最长停顿 1.8s")
    }

    /// The point of capturing the model is catching a gateway that silently
    /// serves something else; an honest echo is not worth showing.
    func testRoutedModelShownOnlyWhenItDiffers() {
        let same = RunMetrics.make(
            total: 1, ttft: 0.1, outputChars: 5, reportedModel: "gpt-4o"
        )
        XCTAssertNil(same.routedModelDisplay(requested: "gpt-4o"))
        XCTAssertEqual(same.routedModelDisplay(requested: "gpt-4o-mini"), "gpt-4o")
    }

    /// Time-to-headers is measured by us and always present; the handshake /
    /// server split comes from URLSession and may not arrive (the OpenAI
    /// dialect cancels the task at `[DONE]`), so the readout must degrade to
    /// the headline alone rather than to nothing.
    func testNetworkDisplayFallsBackToTheHeadlineAlone() {
        let bare = RunMetrics.make(
            total: 1, ttft: 0.4, outputChars: 5,
            network: NetworkTiming(toFirstByte: 0.32)
        )
        XCTAssertEqual(bare.networkDisplay, "首字节 320ms")
    }

    func testNetworkDisplayAddsTheSplitWhenMetricsArrived() {
        let fresh = RunMetrics.make(
            total: 1, ttft: 0.4, outputChars: 5,
            network: NetworkTiming(
                toFirstByte: 0.32, connect: 0.12, serverWait: 0.19, reusedConnection: false
            )
        )
        XCTAssertEqual(fresh.networkDisplay, "首字节 320ms（握手 120ms · 服务端 190ms）")

        let reused = RunMetrics.make(
            total: 1, ttft: 0.4, outputChars: 5,
            network: NetworkTiming(
                toFirstByte: 0.21, connect: nil, serverWait: 0.2, reusedConnection: true
            )
        )
        XCTAssertEqual(reused.networkDisplay, "首字节 210ms（复用连接 · 服务端 200ms）")
    }
}

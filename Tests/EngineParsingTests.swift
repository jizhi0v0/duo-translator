import XCTest
@testable import DuoTranslator

final class EngineParsingTests: XCTestCase {
    private func frame(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testContentDelta() {
        let events = OpenAICompatEngine.events(fromChatFrame:
            frame(#"{"choices":[{"delta":{"content":"你好"}}]}"#))
        XCTAssertEqual(events, [.delta("你好")])
    }

    func testDeepSeekReasoningKey() {
        let events = OpenAICompatEngine.events(fromChatFrame:
            frame(#"{"choices":[{"delta":{"reasoning_content":"思考中"}}]}"#))
        XCTAssertEqual(events, [.reasoning("思考中")])
    }

    func testOpenRouterReasoningKey() {
        let events = OpenAICompatEngine.events(fromChatFrame:
            frame(#"{"choices":[{"delta":{"reasoning":"hmm"}}]}"#))
        XCTAssertEqual(events, [.reasoning("hmm")])
    }

    func testContentAndReasoningInSameFrame() {
        let events = OpenAICompatEngine.events(fromChatFrame:
            frame(#"{"choices":[{"delta":{"content":"A","reasoning":"B"}}]}"#))
        XCTAssertEqual(events, [.delta("A"), .reasoning("B")])
    }

    func testUsageFrame() {
        let events = OpenAICompatEngine.events(fromChatFrame:
            frame(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#))
        XCTAssertEqual(events, [.usage(TokenUsage(prompt: 10, completion: 5, total: 15))])
    }

    /// The `_details` blocks are optional extensions: cached prompt tokens and
    /// reasoning tokens are breakdowns of the counts beside them, not extras.
    func testUsageFrameWithCacheAndReasoningDetails() {
        let events = OpenAICompatEngine.events(fromChatFrame: frame(#"""
        {"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":400,"total_tokens":1600,
         "prompt_tokens_details":{"cached_tokens":1024},
         "completion_tokens_details":{"reasoning_tokens":320}}}
        """#))
        XCTAssertEqual(events, [.usage(TokenUsage(
            prompt: 1200, completion: 400, total: 1600,
            cachedPrompt: 1024, reasoning: 320
        ))])
    }

    /// Every frame echoes the model, which is how a gateway re-route surfaces.
    func testModelIsReportedFromTheFrame() {
        let events = OpenAICompatEngine.events(fromChatFrame:
            frame(#"{"model":"gpt-4o-mini","choices":[{"delta":{"content":"A"}}]}"#))
        XCTAssertEqual(events, [.model("gpt-4o-mini"), .delta("A")])
    }

    func testEmptyDeltaYieldsNothing() {
        let events = OpenAICompatEngine.events(fromChatFrame:
            frame(#"{"choices":[{"delta":{}}]}"#))
        XCTAssertTrue(events.isEmpty)
    }
}

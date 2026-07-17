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
        XCTAssertEqual(events, [.usage(prompt: 10, completion: 5, total: 15)])
    }

    func testEmptyDeltaYieldsNothing() {
        let events = OpenAICompatEngine.events(fromChatFrame:
            frame(#"{"choices":[{"delta":{}}]}"#))
        XCTAssertTrue(events.isEmpty)
    }
}

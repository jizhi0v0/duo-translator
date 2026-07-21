import XCTest
@testable import DuoTranslator

final class VisionOCRRequestTests: XCTestCase {
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A resolved OCR engine: a provider (connection) plus the OCR model.
    private func profile(kind: ProviderKind, baseURL: String = "", model: String = "") -> EngineProfile {
        EngineProfile(provider: Provider(kind: kind, name: "x", baseURL: baseURL), model: model)
    }

    // MARK: - OpenAI-compatible (gpt-4o vision)

    func testOpenAIRequestShape() throws {
        let profile = profile(kind: .openAICompat, baseURL: "https://api.openai.com/v1", model: "gpt-4o")
        let request = try VisionOCRRequest.build(profile: profile, apiKey: "sk-test", base64PNG: "AAAA")

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try body(request)
        XCTAssertEqual(body["model"] as? String, "gpt-4o")
        XCTAssertEqual(body["stream"] as? Bool, false)

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, VisionOCRRequest.prompt)
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(content[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,AAAA")
    }

    func testOpenAITrailingSlashBaseURL() throws {
        let profile = profile(kind: .openAICompat, baseURL: "https://host/v1/", model: "m")
        let request = try VisionOCRRequest.build(profile: profile, apiKey: "k", base64PNG: "z")
        XCTAssertEqual(request.url?.absoluteString, "https://host/v1/chat/completions")
    }

    func testOpenAIParse() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"Hello 世界"}}]}"#
        let text = try VisionOCRRequest.parse(kind: .openAICompat, data: Data(json.utf8))
        XCTAssertEqual(text, "Hello 世界")
    }

    // MARK: - Anthropic (Claude vision)

    func testAnthropicRequestShape() throws {
        let profile = profile(kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-haiku-4-5")
        let request = try VisionOCRRequest.build(profile: profile, apiKey: "ak", base64PNG: "BBBB")

        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "ak")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try body(request)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNotNil(body["max_tokens"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "BBBB")
        XCTAssertEqual(content[1]["type"] as? String, "text")
    }

    func testAnthropicV1SuffixNotDoubled() throws {
        let profile = profile(kind: .anthropic, baseURL: "https://host/v1", model: "m")
        let request = try VisionOCRRequest.build(profile: profile, apiKey: "k", base64PNG: "z")
        XCTAssertEqual(request.url?.absoluteString, "https://host/v1/messages")
    }

    func testAnthropicParseJoinsTextBlocks() throws {
        let json = #"{"content":[{"type":"text","text":"line1\n"},{"type":"text","text":"line2"}]}"#
        let text = try VisionOCRRequest.parse(kind: .anthropic, data: Data(json.utf8))
        XCTAssertEqual(text, "line1\nline2")
    }

    // MARK: - Unsupported kinds & bad payloads

    func testUnsupportedKindThrows() {
        let profile = profile(kind: .deepL)
        XCTAssertThrowsError(try VisionOCRRequest.build(profile: profile, apiKey: "k", base64PNG: "z"))
    }

    func testParseThrowsOnMissingContent() {
        let json = #"{"choices":[{"message":{}}]}"#
        XCTAssertThrowsError(try VisionOCRRequest.parse(kind: .openAICompat, data: Data(json.utf8)))
    }
}

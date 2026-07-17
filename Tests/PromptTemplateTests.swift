import XCTest
@testable import DuoTranslator

final class PromptTemplateTests: XCTestCase {
    func testRenderReplacesTarget() {
        let rendered = PromptTemplate.render("Translate into {{target}}.", target: "zh-Hans")
        XCTAssertEqual(rendered, "Translate into Simplified Chinese.")
    }

    func testEngineErrorExtractsOpenAIMessage() {
        let body = #"{"error": {"message": "Invalid API key", "type": "auth"}}"#
        let error = EngineError.http(status: 401, body: body)
        XCTAssertTrue(error.localizedDescription.contains("Invalid API key"))
    }
}

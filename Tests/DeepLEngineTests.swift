import XCTest
@testable import DuoTranslator

final class DeepLEngineTests: XCTestCase {
    func testTargetLanguageMapping() {
        XCTAssertEqual(DeepLEngine.mapTarget("zh-Hans"), "ZH-HANS")
        XCTAssertEqual(DeepLEngine.mapTarget("zh-Hant"), "ZH-HANT")
        XCTAssertEqual(DeepLEngine.mapTarget("en"), "EN-US")
        XCTAssertEqual(DeepLEngine.mapTarget("pt"), "PT-BR")
        XCTAssertEqual(DeepLEngine.mapTarget("ja"), "JA")
        XCTAssertEqual(DeepLEngine.mapTarget("de"), "DE")
    }
}

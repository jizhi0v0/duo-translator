import XCTest
@testable import DuoTranslator

final class LanguagePolicyTests: XCTestCase {
    func testDetectChinese() {
        XCTAssertEqual(LanguagePolicy.detect("这是一个中文句子"), "zh-Hans")
    }

    func testDetectShortChinese() {
        XCTAssertEqual(LanguagePolicy.detect("你好"), "zh-Hans")
    }

    func testDetectJapaneseKanaWins() {
        XCTAssertEqual(LanguagePolicy.detect("これは日本語です"), "ja")
    }

    func testDetectKorean() {
        XCTAssertEqual(LanguagePolicy.detect("안녕하세요"), "ko")
    }

    func testDetectEnglish() {
        XCTAssertEqual(LanguagePolicy.detect("The quick brown fox jumps over the lazy dog"), "en")
    }

    func testAutoSwapChineseToSecond() {
        let target = LanguagePolicy.target(for: "中文文本", first: "zh-Hans", second: "en")
        XCTAssertEqual(target, "en")
    }

    func testAutoSwapEnglishToFirst() {
        let target = LanguagePolicy.target(for: "Hello world, this is a test", first: "zh-Hans", second: "en")
        XCTAssertEqual(target, "zh-Hans")
    }

    func testEnglishNames() {
        XCTAssertEqual(LanguagePolicy.englishName(for: "zh-Hans"), "Simplified Chinese")
        XCTAssertEqual(LanguagePolicy.englishName(for: "ja"), "Japanese")
    }
}

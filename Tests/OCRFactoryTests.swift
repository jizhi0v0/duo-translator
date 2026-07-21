import XCTest
@testable import DuoTranslator

/// The OCR selection resolves to a live provider, falling back to Apple Vision
/// whenever the selection can't produce a working LLM vision backend.
@MainActor
final class OCRFactoryTests: XCTestCase {
    private func store(_ name: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: "OCRFactoryTests.\(name)")!
        defaults.removePersistentDomain(forName: "OCRFactoryTests.\(name)")
        return SettingsStore(defaults: defaults)
    }

    func testEmptySelectionUsesAppleVision() {
        let settings = store("Empty")
        settings.ocrProviderID = ""
        let provider = OCRFactory.makeProvider(settings: settings, keychain: .shared)
        XCTAssertTrue(provider is AppleVisionOCRProvider)
    }

    func testLLMProviderResolvesToLLMVision() {
        let settings = store("LLM")
        let p = Provider(kind: .openAICompat, name: "OpenAI", baseURL: "https://h/v1")
        settings.providers = [p]
        settings.ocrProviderID = p.id.uuidString
        settings.ocrModel = "gpt-4o"
        let provider = OCRFactory.makeProvider(settings: settings, keychain: .shared)
        XCTAssertTrue(provider is LLMVisionOCRProvider)
    }

    func testStaleIDFallsBackToApple() {
        let settings = store("Stale")
        settings.ocrProviderID = UUID().uuidString // no such provider
        let provider = OCRFactory.makeProvider(settings: settings, keychain: .shared)
        XCTAssertTrue(provider is AppleVisionOCRProvider)
    }

    func testAppleProviderSelectionFallsBackToApple() {
        let settings = store("AppleProvider")
        let p = Provider(kind: .apple, name: "Apple 本地")
        settings.providers = [p]
        settings.ocrProviderID = p.id.uuidString // apple kind can't do LLM vision
        let provider = OCRFactory.makeProvider(settings: settings, keychain: .shared)
        XCTAssertTrue(provider is AppleVisionOCRProvider)
    }
}

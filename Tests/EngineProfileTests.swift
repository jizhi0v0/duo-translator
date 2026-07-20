import XCTest
@testable import DuoTranslator

final class EngineProfileTests: XCTestCase {
    func testNormalizeStripsPastedWhitespace() {
        var profile = EngineProfile(kind: .openAICompat, name: "  OpenAI\n",
                                    baseURL: " https://api.openai.com/v1 ", model: "gpt-5.6-terra\n")
        profile.normalize()
        XCTAssertEqual(profile.name, "OpenAI")
        XCTAssertEqual(profile.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(profile.model, "gpt-5.6-terra")
    }

    @MainActor
    func testStoreNormalizesOnAssignment() {
        let defaults = UserDefaults(suiteName: "EngineProfileTests")!
        defaults.removePersistentDomain(forName: "EngineProfileTests")
        let store = SettingsStore(defaults: defaults)
        var profile = EngineProfile.makeDefault(kind: .openAICompat)
        profile.model = "gpt-5.6-terra\n"
        store.engineProfiles = [profile]
        XCTAssertEqual(store.engineProfiles.first?.model, "gpt-5.6-terra")
    }

    /// Regression: a profile saved before a field existed must still decode.
    /// Swift's synthesized `Decodable` throws `keyNotFound` rather than using
    /// the property's default, so adding one persisted field made every stored
    /// engine unreadable — the store fell back to a fresh default profile whose
    /// id no longer matched the keychain, and a configured app reported
    /// "未配置 API Key".
    func testProfileSavedBeforeThePriceFieldsStillDecodes() throws {
        let legacy = Data("""
        [{"id":"53E6F006-D96F-495D-805C-F1D2DFB1C00D","kind":"openAICompat","name":"OpenAI",
          "enabled":true,"baseURL":"https://api.openai.com/v1","model":"gpt-4o-mini",
          "systemPromptTemplate":"translate"}]
        """.utf8)

        let profiles = try JSONDecoder().decode([EngineProfile].self, from: legacy)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id.uuidString, "53E6F006-D96F-495D-805C-F1D2DFB1C00D",
                       "the id must survive — the keychain secret is filed under it")
        XCTAssertEqual(profiles[0].model, "gpt-4o-mini")
        XCTAssertEqual(profiles[0].inputPricePerMTok, 0, "an absent price reads as unknown")
        XCTAssertEqual(profiles[0].cachedInputPricePerMTok, 0)
    }

    func testOnlyKindAndNameAreRequired() throws {
        let minimal = Data(#"{"kind":"apple","name":"Apple 翻译"}"#.utf8)
        let profile = try JSONDecoder().decode(EngineProfile.self, from: minimal)
        XCTAssertEqual(profile.name, "Apple 翻译")
        XCTAssertTrue(profile.enabled, "defaults fill in for everything else")
        XCTAssertEqual(profile.systemPromptTemplate, EngineProfile.defaultPromptTemplate)
    }

    func testRoundTripKeepsPrices() throws {
        var profile = EngineProfile.makeDefault(kind: .openAICompat)
        profile.inputPricePerMTok = 3
        profile.outputPricePerMTok = 15
        profile.cachedInputPricePerMTok = 0.3

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(EngineProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }
}

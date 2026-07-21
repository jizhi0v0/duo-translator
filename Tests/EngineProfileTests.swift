import XCTest
@testable import DuoTranslator

/// Covers the provider/config data model and the one-time migration from the
/// legacy flat `engineProfiles` shape.
final class EngineProfileTests: XCTestCase {
    // MARK: - Normalization & tolerant decoding

    func testProviderNormalizeStripsPastedWhitespace() {
        var provider = Provider(kind: .openAICompat, name: "  OpenAI\n",
                                baseURL: " https://api.openai.com/v1 ")
        provider.normalize()
        XCTAssertEqual(provider.name, "OpenAI")
        XCTAssertEqual(provider.baseURL, "https://api.openai.com/v1")
    }

    func testConfigNormalizeStripsPastedWhitespace() {
        var config = TranslationConfig(providerID: UUID(), name: "  Card\n", model: "gpt-5.6-terra\n")
        config.normalize()
        XCTAssertEqual(config.name, "Card")
        XCTAssertEqual(config.model, "gpt-5.6-terra")
    }

    @MainActor
    func testStoreNormalizesConfigOnAssignment() {
        let store = freshStore("StoreNormalizesConfig")
        let providerID = store.providers.first!.id
        store.translationConfigs = [TranslationConfig(providerID: providerID, name: "x", model: "gpt-5.6-terra\n")]
        XCTAssertEqual(store.translationConfigs.first?.model, "gpt-5.6-terra")
    }

    /// Regression: a value saved before a field existed must still decode.
    /// Swift's synthesized `Decodable` throws `keyNotFound` rather than using the
    /// property default, so a single added persisted field would otherwise make
    /// the whole store unreadable and reset — losing the id the keychain is
    /// filed under.
    func testConfigSavedBeforeThePriceFieldsStillDecodes() throws {
        let legacy = Data("""
        [{"id":"53E6F006-D96F-495D-805C-F1D2DFB1C00D","providerID":"53E6F006-D96F-495D-805C-F1D2DFB1C00D",
          "name":"OpenAI","enabled":true,"model":"gpt-4o-mini","systemPromptTemplate":"translate"}]
        """.utf8)
        let configs = try JSONDecoder().decode([TranslationConfig].self, from: legacy)
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs[0].id.uuidString, "53E6F006-D96F-495D-805C-F1D2DFB1C00D")
        XCTAssertEqual(configs[0].model, "gpt-4o-mini")
        XCTAssertEqual(configs[0].inputPricePerMTok, 0, "an absent price reads as unknown")
    }

    func testProviderOnlyKindAndNameAreRequired() throws {
        let minimal = Data(#"{"kind":"apple","name":"Apple 本地"}"#.utf8)
        let provider = try JSONDecoder().decode(Provider.self, from: minimal)
        XCTAssertEqual(provider.name, "Apple 本地")
        XCTAssertEqual(provider.baseURL, "", "defaults fill in for everything else")
    }

    func testConfigRoundTripKeepsPrices() throws {
        var config = TranslationConfig(providerID: UUID(), name: "x", model: "m")
        config.inputPricePerMTok = 3
        config.outputPricePerMTok = 15
        config.cachedInputPricePerMTok = 0.3
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TranslationConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - Legacy migration

    @MainActor
    func testMigratesLegacyEngineProfilesPreservingIDs() {
        let defaults = suite("MigrateLegacy")
        let id = "53E6F006-D96F-495D-805C-F1D2DFB1C00D"
        defaults.set(Data("""
        [{"id":"\(id)","kind":"openAICompat","name":"OpenAI","enabled":true,
          "baseURL":"https://api.openai.com/v1","model":"gpt-4o-mini",
          "systemPromptTemplate":"translate","inputPricePerMTok":3}]
        """.utf8), forKey: SettingsStore.Keys.engineProfiles)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers.first?.id.uuidString, id,
                       "provider keeps the id — the keychain secret is filed under it")
        XCTAssertEqual(store.providers.first?.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(store.translationConfigs.count, 1)
        XCTAssertEqual(store.translationConfigs.first?.id.uuidString, id,
                       "card keeps the id — per-card layout is keyed by it")
        XCTAssertEqual(store.translationConfigs.first?.providerID.uuidString, id)
        XCTAssertEqual(store.translationConfigs.first?.model, "gpt-4o-mini")
        XCTAssertEqual(store.translationConfigs.first?.inputPricePerMTok, 3)
        XCTAssertEqual(store.resolvedEnabledEngines.count, 1)
    }

    @MainActor
    func testMigratesLegacyOCRSelectionAndModel() {
        let defaults = suite("MigrateLegacyOCR")
        let id = "53E6F006-D96F-495D-805C-F1D2DFB1C00D"
        defaults.set(Data("""
        [{"id":"\(id)","kind":"openAICompat","name":"OpenAI","enabled":true,
          "baseURL":"https://h/v1","model":"gpt-4o"}]
        """.utf8), forKey: SettingsStore.Keys.engineProfiles)
        defaults.set(id, forKey: SettingsStore.Keys.ocrProvider)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ocrProviderID, id, "OCR now points at the migrated provider")
        XCTAssertEqual(store.ocrModel, "gpt-4o", "OCR carries over the model it used to share")
    }

    @MainActor
    func testLegacyAppleOCRMapsToBuiltIn() {
        let defaults = suite("MigrateLegacyApple")
        defaults.set(Data("""
        [{"id":"53E6F006-D96F-495D-805C-F1D2DFB1C00D","kind":"apple","name":"Apple","enabled":true}]
        """.utf8), forKey: SettingsStore.Keys.engineProfiles)
        defaults.set("apple", forKey: SettingsStore.Keys.ocrProvider)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ocrProviderID, "", "Apple built-in Vision is the empty sentinel")
    }

    @MainActor
    func testFreshInstallSeedsOneProviderAndCard() {
        let store = freshStore("FreshSeed")
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers.first?.kind, .openAICompat)
        XCTAssertEqual(store.translationConfigs.count, 1)
        XCTAssertEqual(store.translationConfigs.first?.providerID, store.providers.first?.id)
        XCTAssertEqual(store.ocrProviderID, "")
    }

    // MARK: - Helpers

    private func suite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "EngineProfileTests.\(name)")!
        defaults.removePersistentDomain(forName: "EngineProfileTests.\(name)")
        return defaults
    }

    @MainActor
    private func freshStore(_ name: String) -> SettingsStore {
        SettingsStore(defaults: suite(name))
    }
}

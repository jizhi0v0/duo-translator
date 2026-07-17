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
}

import Foundation
import Combine

/// Single source of truth for user preferences, persisted to UserDefaults.
/// M5 layers an iCloud KVS mirror on top of the same keys.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    enum Keys {
        static let firstLanguage = "firstLanguage"
        static let secondLanguage = "secondLanguage"
        static let engineProfiles = "engineProfiles"
        static let ocrLanguages = "ocrLanguages"
        static let ocrMergesLines = "ocrMergesLines"
        static let ocrProvider = "ocrProvider"
        static let ocrVisionLevel = "ocrVisionLevel"
    }

    @Published var firstLanguage: String {
        didSet { defaults.set(firstLanguage, forKey: Keys.firstLanguage) }
    }
    @Published var secondLanguage: String {
        didSet { defaults.set(secondLanguage, forKey: Keys.secondLanguage) }
    }
    @Published var engineProfiles: [EngineProfile] {
        didSet {
            let normalized = engineProfiles.map { profile -> EngineProfile in
                var copy = profile
                copy.normalize()
                return copy
            }
            // Re-assigning re-enters didSet; the second pass is a no-op and stops here.
            guard normalized == engineProfiles else {
                engineProfiles = normalized
                return
            }
            persistProfiles()
        }
    }
    @Published var ocrLanguages: [String] {
        didSet { defaults.set(ocrLanguages, forKey: Keys.ocrLanguages) }
    }
    @Published var ocrMergesLines: Bool {
        didSet { defaults.set(ocrMergesLines, forKey: Keys.ocrMergesLines) }
    }
    /// Active OCR provider: `"apple"` for built-in Vision, or an engine profile
    /// UUID string for a vision-capable LLM. Resolved by `OCRFactory`, which
    /// falls back to Apple when the id no longer matches an LLM engine.
    @Published var ocrProvider: String {
        didSet { defaults.set(ocrProvider, forKey: Keys.ocrProvider) }
    }
    /// Apple Vision precision: `"accurate"` (default) or `"fast"`.
    @Published var ocrVisionLevel: String {
        didSet { defaults.set(ocrVisionLevel, forKey: Keys.ocrVisionLevel) }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        firstLanguage = defaults.string(forKey: Keys.firstLanguage) ?? "zh-Hans"
        secondLanguage = defaults.string(forKey: Keys.secondLanguage) ?? "en"
        ocrLanguages = defaults.stringArray(forKey: Keys.ocrLanguages) ?? ["zh-Hans", "zh-Hant", "en-US", "ja"]
        ocrMergesLines = defaults.object(forKey: Keys.ocrMergesLines) as? Bool ?? true
        ocrProvider = defaults.string(forKey: Keys.ocrProvider) ?? "apple"
        ocrVisionLevel = defaults.string(forKey: Keys.ocrVisionLevel) ?? "accurate"

        if let data = defaults.data(forKey: Keys.engineProfiles),
           let profiles = try? JSONDecoder().decode([EngineProfile].self, from: data) {
            engineProfiles = profiles
        } else {
            engineProfiles = [EngineProfile.makeDefault(kind: .openAICompat)]
        }
    }

    var enabledProfiles: [EngineProfile] {
        engineProfiles.filter(\.enabled)
    }

    /// Re-read every published value from UserDefaults after CloudSync applied
    /// remote changes. Assignments re-fire didSet, but writing an identical
    /// value back to defaults is harmless and CloudSync skips no-op pushes.
    func reloadFromDefaults() {
        firstLanguage = defaults.string(forKey: Keys.firstLanguage) ?? firstLanguage
        secondLanguage = defaults.string(forKey: Keys.secondLanguage) ?? secondLanguage
        ocrLanguages = defaults.stringArray(forKey: Keys.ocrLanguages) ?? ocrLanguages
        ocrMergesLines = defaults.object(forKey: Keys.ocrMergesLines) as? Bool ?? ocrMergesLines
        ocrProvider = defaults.string(forKey: Keys.ocrProvider) ?? ocrProvider
        ocrVisionLevel = defaults.string(forKey: Keys.ocrVisionLevel) ?? ocrVisionLevel
        if let data = defaults.data(forKey: Keys.engineProfiles),
           let profiles = try? JSONDecoder().decode([EngineProfile].self, from: data) {
            engineProfiles = profiles
        }
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(engineProfiles) {
            defaults.set(data, forKey: Keys.engineProfiles)
        }
    }

    /// Candidate languages offered in pickers.
    static let languageChoices: [String] = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "ru", "pt", "it",
    ]
}

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
        static let resultBodyHeight = "resultBodyHeight"
        static let resultBodyHeightByEngine = "resultBodyHeightByEngine"
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
    /// Result-card body height the user dragged for every card, or 0 for "auto"
    /// (follow the streamed content up to the card's share of the window).
    @Published var resultBodyHeight: Double {
        didSet { defaults.set(resultBodyHeight, forKey: Keys.resultBodyHeight) }
    }
    /// Per-engine overrides of `resultBodyHeight`, keyed by engine profile id.
    @Published var resultBodyHeightByEngine: [String: Double] {
        didSet { defaults.set(resultBodyHeightByEngine, forKey: Keys.resultBodyHeightByEngine) }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        firstLanguage = defaults.string(forKey: Keys.firstLanguage) ?? "zh-Hans"
        secondLanguage = defaults.string(forKey: Keys.secondLanguage) ?? "en"
        ocrLanguages = defaults.stringArray(forKey: Keys.ocrLanguages) ?? ["zh-Hans", "zh-Hant", "en-US", "ja"]
        ocrMergesLines = defaults.object(forKey: Keys.ocrMergesLines) as? Bool ?? true
        resultBodyHeight = defaults.double(forKey: Keys.resultBodyHeight)
        resultBodyHeightByEngine =
            defaults.dictionary(forKey: Keys.resultBodyHeightByEngine) as? [String: Double] ?? [:]

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
        resultBodyHeight = defaults.object(forKey: Keys.resultBodyHeight) as? Double ?? resultBodyHeight
        resultBodyHeightByEngine =
            defaults.dictionary(forKey: Keys.resultBodyHeightByEngine) as? [String: Double]
            ?? resultBodyHeightByEngine
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

    /// Drop the panel-layout preferences a UI test may have written (and any
    /// left over from a previous run), so every test starts from the automatic
    /// behaviour and none of them touch the user's real settings.
    static func resetForUITests() {
        shared.clearAllResultBodyHeights()
    }

    /// Height the card for `engineID` should use: its own dragged height, else
    /// the one dragged for every card, else nil for auto.
    func resultBodyHeight(for engineID: String) -> CGFloat? {
        if let own = resultBodyHeightByEngine[engineID], own > 0 { return own }
        return resultBodyHeight > 0 ? resultBodyHeight : nil
    }

    /// Drag committed on one card's divider.
    func setResultBodyHeight(_ height: CGFloat, for engineID: String) {
        resultBodyHeightByEngine[engineID] = Double(height)
    }

    /// Drag committed with ⌥: every card gets it, and per-card overrides are
    /// dropped so the new height actually applies everywhere.
    func setResultBodyHeightForAllEngines(_ height: CGFloat) {
        resultBodyHeight = Double(height)
        resultBodyHeightByEngine.removeAll()
    }

    /// Back to auto: this card follows its content again.
    func clearResultBodyHeight(for engineID: String) {
        resultBodyHeightByEngine[engineID] = nil
    }

    func clearAllResultBodyHeights() {
        resultBodyHeight = 0
        resultBodyHeightByEngine.removeAll()
    }

    /// Candidate languages offered in pickers.
    static let languageChoices: [String] = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "ru", "pt", "it",
    ]
}

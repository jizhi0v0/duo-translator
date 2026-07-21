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
        /// Provider/config split (current schema).
        static let providers = "providers"
        static let translationConfigs = "translationConfigs"
        static let ocrProviderID = "ocrProviderID"
        static let ocrModel = "ocrModel"
        /// Legacy keys, read once by the migration then left untouched.
        static let engineProfiles = "engineProfiles"
        static let ocrProvider = "ocrProvider"

        static let ocrLanguages = "ocrLanguages"
        static let ocrMergesLines = "ocrMergesLines"
        static let resultBodyHeight = "resultBodyHeight"
        static let resultBodyHeightByEngine = "resultBodyHeightByEngine"
        static let ocrVisionLevel = "ocrVisionLevel"
    }

    @Published var firstLanguage: String {
        didSet { defaults.set(firstLanguage, forKey: Keys.firstLanguage) }
    }
    @Published var secondLanguage: String {
        didSet { defaults.set(secondLanguage, forKey: Keys.secondLanguage) }
    }
    /// Reusable connections. Referenced by `translationConfigs` and the OCR
    /// selection via id; the API key is in the keychain under the provider id.
    @Published var providers: [Provider] {
        didSet {
            let normalized = providers.map { p -> Provider in var c = p; c.normalize(); return c }
            guard normalized == providers else { providers = normalized; return }
            persist(providers, forKey: Keys.providers)
        }
    }
    /// Translation result cards, in card order.
    @Published var translationConfigs: [TranslationConfig] {
        didSet {
            let normalized = translationConfigs.map { c -> TranslationConfig in
                var copy = c; copy.normalize(); return copy
            }
            guard normalized == translationConfigs else { translationConfigs = normalized; return }
            persist(translationConfigs, forKey: Keys.translationConfigs)
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
    /// Per-card overrides of `resultBodyHeight`, keyed by translation config id.
    @Published var resultBodyHeightByEngine: [String: Double] {
        didSet { defaults.set(resultBodyHeightByEngine, forKey: Keys.resultBodyHeightByEngine) }
    }
    /// Active OCR provider: empty for the built-in Apple Vision, or a provider
    /// UUID string for a vision-capable LLM. Resolved by `OCRFactory`, which
    /// falls back to Apple when the id no longer matches an OCR-capable provider.
    @Published var ocrProviderID: String {
        didSet { defaults.set(ocrProviderID, forKey: Keys.ocrProviderID) }
    }
    /// Model used for LLM OCR, independent of any translation card's model.
    @Published var ocrModel: String {
        didSet { defaults.set(ocrModel, forKey: Keys.ocrModel) }
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
        resultBodyHeight = defaults.double(forKey: Keys.resultBodyHeight)
        resultBodyHeightByEngine =
            defaults.dictionary(forKey: Keys.resultBodyHeightByEngine) as? [String: Double] ?? [:]
        ocrVisionLevel = defaults.string(forKey: Keys.ocrVisionLevel) ?? "accurate"

        // Provider/config: load the current schema, else migrate from the legacy
        // `engineProfiles`/`ocrProvider` shape, else seed a default.
        if let loaded = Self.loadProviderSchema(from: defaults) {
            providers = loaded.providers
            translationConfigs = loaded.configs
            ocrProviderID = loaded.ocrProviderID
            ocrModel = loaded.ocrModel
        } else if let migrated = Self.migrateLegacy(from: defaults) {
            providers = migrated.providers
            translationConfigs = migrated.configs
            ocrProviderID = migrated.ocrProviderID
            ocrModel = migrated.ocrModel
            Self.persist(migrated.providers, forKey: Keys.providers, in: defaults)
            Self.persist(migrated.configs, forKey: Keys.translationConfigs, in: defaults)
            defaults.set(migrated.ocrProviderID, forKey: Keys.ocrProviderID)
            defaults.set(migrated.ocrModel, forKey: Keys.ocrModel)
        } else {
            let seed = Self.seedDefault()
            providers = seed.providers
            translationConfigs = seed.configs
            ocrProviderID = ""
            ocrModel = ""
        }
    }

    // MARK: - Derived

    var enabledConfigs: [TranslationConfig] {
        translationConfigs.filter(\.enabled)
    }

    func provider(id: UUID) -> Provider? {
        providers.first { $0.id == id }
    }

    /// A translation card merged with its provider, or nil if the provider is
    /// gone. Skipping the nil ones is how a dangling reference stops producing a
    /// broken engine instead of crashing.
    func resolvedEngine(for config: TranslationConfig) -> EngineProfile? {
        guard let provider = provider(id: config.providerID) else { return nil }
        return EngineProfile(provider: provider, config: config)
    }

    /// Every enabled card that still resolves to a provider, in card order.
    var resolvedEnabledEngines: [EngineProfile] {
        enabledConfigs.compactMap(resolvedEngine)
    }

    /// Resolve by engine id (a card's `TranslationConfig.id.uuidString`), used by
    /// per-card retry and the metrics/pricing lookup keyed on `run.id`.
    func resolvedEngine(engineID: String) -> EngineProfile? {
        guard let id = UUID(uuidString: engineID),
              let config = translationConfigs.first(where: { $0.id == id }) else { return nil }
        return resolvedEngine(for: config)
    }

    // MARK: - Sync reload

    /// Re-read every published value from UserDefaults after CloudSync applied
    /// remote changes.
    func reloadFromDefaults() {
        firstLanguage = defaults.string(forKey: Keys.firstLanguage) ?? firstLanguage
        secondLanguage = defaults.string(forKey: Keys.secondLanguage) ?? secondLanguage
        ocrLanguages = defaults.stringArray(forKey: Keys.ocrLanguages) ?? ocrLanguages
        ocrMergesLines = defaults.object(forKey: Keys.ocrMergesLines) as? Bool ?? ocrMergesLines
        resultBodyHeight = defaults.object(forKey: Keys.resultBodyHeight) as? Double ?? resultBodyHeight
        resultBodyHeightByEngine =
            defaults.dictionary(forKey: Keys.resultBodyHeightByEngine) as? [String: Double]
            ?? resultBodyHeightByEngine
        ocrVisionLevel = defaults.string(forKey: Keys.ocrVisionLevel) ?? ocrVisionLevel
        ocrProviderID = defaults.string(forKey: Keys.ocrProviderID) ?? ocrProviderID
        ocrModel = defaults.string(forKey: Keys.ocrModel) ?? ocrModel
        if let loaded = Self.loadProviderSchema(from: defaults) {
            providers = loaded.providers
            translationConfigs = loaded.configs
        }
    }

    // MARK: - Persistence helpers

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        Self.persist(value, forKey: key, in: defaults)
    }

    private static func persist<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadProviderSchema(
        from defaults: UserDefaults
    ) -> (providers: [Provider], configs: [TranslationConfig], ocrProviderID: String, ocrModel: String)? {
        guard let pData = defaults.data(forKey: Keys.providers),
              let providers = try? JSONDecoder().decode([Provider].self, from: pData) else {
            return nil
        }
        let configs = (defaults.data(forKey: Keys.translationConfigs))
            .flatMap { try? JSONDecoder().decode([TranslationConfig].self, from: $0) } ?? []
        return (
            providers,
            configs,
            defaults.string(forKey: Keys.ocrProviderID) ?? "",
            defaults.string(forKey: Keys.ocrModel) ?? ""
        )
    }

    // MARK: - Migration

    /// Old persisted engine profile, mirrored just enough to migrate. `kind`
    /// raw values match `ProviderKind`, so decoding straight into it works.
    private struct LegacyEngineProfile: Decodable {
        var id: UUID
        var kind: ProviderKind
        var name: String
        var enabled: Bool
        var baseURL: String
        var model: String
        var systemPromptTemplate: String
        var inputPricePerMTok: Double
        var outputPricePerMTok: Double
        var cachedInputPricePerMTok: Double

        // Decodable-only + manual init(from:) means no synthesized CodingKeys.
        enum CodingKeys: String, CodingKey {
            case id, kind, name, enabled, baseURL, model, systemPromptTemplate
            case inputPricePerMTok, outputPricePerMTok, cachedInputPricePerMTok
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            kind = try c.decode(ProviderKind.self, forKey: .kind)
            name = try c.decode(String.self, forKey: .name)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
            systemPromptTemplate = try c.decodeIfPresent(String.self, forKey: .systemPromptTemplate)
                ?? TranslationConfig.defaultPromptTemplate
            inputPricePerMTok = try c.decodeIfPresent(Double.self, forKey: .inputPricePerMTok) ?? 0
            outputPricePerMTok = try c.decodeIfPresent(Double.self, forKey: .outputPricePerMTok) ?? 0
            cachedInputPricePerMTok = try c.decodeIfPresent(Double.self, forKey: .cachedInputPricePerMTok) ?? 0
        }
    }

    /// One-time, idempotent conversion of the legacy flat `engineProfiles` +
    /// `ocrProvider` into providers + cards + OCR selection. Each old profile
    /// becomes one provider and one card **sharing the profile's UUID**, so the
    /// keychain key (by provider id) and the per-card layout overrides (by card
    /// id) both keep resolving. Returns nil when there's nothing to migrate.
    private static func migrateLegacy(
        from defaults: UserDefaults
    ) -> (providers: [Provider], configs: [TranslationConfig], ocrProviderID: String, ocrModel: String)? {
        guard let data = defaults.data(forKey: Keys.engineProfiles),
              let legacy = try? JSONDecoder().decode([LegacyEngineProfile].self, from: data),
              !legacy.isEmpty else {
            return nil
        }

        let providers = legacy.map { Provider(id: $0.id, kind: $0.kind, name: $0.name, baseURL: $0.baseURL) }
        let configs = legacy.map {
            TranslationConfig(
                id: $0.id,
                providerID: $0.id,
                name: $0.name,
                enabled: $0.enabled,
                model: $0.model,
                systemPromptTemplate: $0.systemPromptTemplate,
                inputPricePerMTok: $0.inputPricePerMTok,
                outputPricePerMTok: $0.outputPricePerMTok,
                cachedInputPricePerMTok: $0.cachedInputPricePerMTok
            )
        }

        // Old OCR selection: "apple"/absent → built-in; a UUID → that provider,
        // and carry over the model the profile used (OCR reused it before).
        var ocrProviderID = ""
        var ocrModel = ""
        let legacyOCR = defaults.string(forKey: Keys.ocrProvider) ?? "apple"
        if legacyOCR != "apple", let id = UUID(uuidString: legacyOCR),
           let match = legacy.first(where: { $0.id == id }) {
            ocrProviderID = id.uuidString
            ocrModel = match.model
        }

        return (providers, configs, ocrProviderID, ocrModel)
    }

    /// Fresh install: one OpenAI-compatible provider and one card using it,
    /// matching the app's previous single-default-engine behaviour.
    private static func seedDefault() -> (providers: [Provider], configs: [TranslationConfig]) {
        let provider = Provider.makeDefault(kind: .openAICompat)
        let config = TranslationConfig(
            providerID: provider.id,
            name: provider.name,
            model: provider.defaultModel
        )
        return ([provider], [config])
    }

    // MARK: - Result-card layout

    /// Drop the panel-layout preferences a UI test may have written, so every
    /// test starts from the automatic behaviour.
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

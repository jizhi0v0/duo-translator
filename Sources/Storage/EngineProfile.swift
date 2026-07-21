import Foundation

/// A resolved, ready-to-run translation engine: a `Provider` (connection) merged
/// with the model/prompt/pricing of the thing that uses it — a `TranslationConfig`
/// card, or the OCR selection. **Not persisted** (that role split into `Provider`
/// + `TranslationConfig`); it exists only so the engines and `VisionOCRRequest`
/// keep consuming a single value with `kind` / `baseURL` / `model` / prompt in
/// one place, unchanged from before the provider/config split.
struct EngineProfile: Identifiable, Hashable, Sendable {
    /// Identity of the *thing being run* — a card's `TranslationConfig.id` (so
    /// retry, metrics and per-card layout keep lining up). Not the provider id.
    var id: UUID
    /// Provider id, used only to fetch the API key from the keychain.
    var providerID: UUID
    var kind: ProviderKind
    var name: String
    var baseURL: String
    var model: String
    var systemPromptTemplate: String
    var inputPricePerMTok: Double
    var outputPricePerMTok: Double
    var cachedInputPricePerMTok: Double

    init(
        id: UUID,
        providerID: UUID,
        kind: ProviderKind,
        name: String,
        baseURL: String = "",
        model: String = "",
        systemPromptTemplate: String = TranslationConfig.defaultPromptTemplate,
        inputPricePerMTok: Double = 0,
        outputPricePerMTok: Double = 0,
        cachedInputPricePerMTok: Double = 0
    ) {
        self.id = id
        self.providerID = providerID
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.systemPromptTemplate = systemPromptTemplate
        self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok
        self.cachedInputPricePerMTok = cachedInputPricePerMTok
    }

    /// Resolve a translation card against its provider. The engine's identity is
    /// the card's, the connection is the provider's.
    init(provider: Provider, config: TranslationConfig) {
        self.init(
            id: config.id,
            providerID: provider.id,
            kind: provider.kind,
            name: config.name,
            baseURL: provider.baseURL,
            model: config.model,
            systemPromptTemplate: config.systemPromptTemplate,
            inputPricePerMTok: config.inputPricePerMTok,
            outputPricePerMTok: config.outputPricePerMTok,
            cachedInputPricePerMTok: config.cachedInputPricePerMTok
        )
    }

    /// Resolve an OCR selection: a provider plus the OCR model, with no
    /// translation prompt or pricing (OCR uses its own fixed prompt).
    init(provider: Provider, model: String) {
        self.init(
            id: provider.id,
            providerID: provider.id,
            kind: provider.kind,
            name: provider.name,
            baseURL: provider.baseURL,
            model: model
        )
    }
}

import Foundation

/// One translation result card: which provider to use, which model, the system
/// prompt and per-model pricing. The connection details (kind, base URL, key)
/// live on the referenced `Provider`, so several cards can share one provider
/// with different models. Formerly the translation half of `EngineProfile`.
struct TranslationConfig: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// The `Provider` this card connects through.
    var providerID: UUID
    var name: String
    var enabled: Bool = true
    /// LLM providers only.
    var model: String = ""
    var systemPromptTemplate: String = TranslationConfig.defaultPromptTemplate
    /// Price per million tokens, in whatever currency the provider quotes.
    /// Zero means unknown — the per-run readout then omits cost. Kept per card
    /// because prices are per model and change often.
    var inputPricePerMTok: Double = 0
    var outputPricePerMTok: Double = 0
    /// Discounted rate for prompt tokens served from the provider's cache;
    /// zero falls back to `inputPricePerMTok`.
    var cachedInputPricePerMTok: Double = 0

    /// Field-by-field `decodeIfPresent` so an added field never fails the whole
    /// store's decode (see the note in `Provider.init(from:)`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        providerID = try c.decode(UUID.self, forKey: .providerID)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        systemPromptTemplate = try c.decodeIfPresent(String.self, forKey: .systemPromptTemplate)
            ?? Self.defaultPromptTemplate
        inputPricePerMTok = try c.decodeIfPresent(Double.self, forKey: .inputPricePerMTok) ?? 0
        outputPricePerMTok = try c.decodeIfPresent(Double.self, forKey: .outputPricePerMTok) ?? 0
        cachedInputPricePerMTok =
            try c.decodeIfPresent(Double.self, forKey: .cachedInputPricePerMTok) ?? 0
    }

    /// Memberwise init, which the custom `init(from:)` above suppresses.
    init(
        id: UUID = UUID(),
        providerID: UUID,
        name: String,
        enabled: Bool = true,
        model: String = "",
        systemPromptTemplate: String = TranslationConfig.defaultPromptTemplate,
        inputPricePerMTok: Double = 0,
        outputPricePerMTok: Double = 0,
        cachedInputPricePerMTok: Double = 0
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.enabled = enabled
        self.model = model
        self.systemPromptTemplate = systemPromptTemplate
        self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok
        self.cachedInputPricePerMTok = cachedInputPricePerMTok
    }

    static let defaultPromptTemplate = """
    You are a professional translation engine. Translate the user's text into {{target}}. \
    Preserve the original formatting, line breaks and markdown. \
    Output only the translation, with no explanations and no quotes around it.
    """

    mutating func normalize() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

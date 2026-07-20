import Foundation

enum EngineKind: String, Codable, CaseIterable, Sendable {
    case openAICompat
    case anthropic
    case deepL
    case apple

    var label: String {
        switch self {
        case .openAICompat: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .deepL: return "DeepL"
        case .apple: return "Apple 本地翻译"
        }
    }

    var needsAPIKey: Bool { self != .apple }

    /// Token-streaming LLM backends. Only these produce meaningful throughput /
    /// first-token metrics; DeepL and Apple are single-shot and are excluded
    /// from the per-run performance readout.
    var isLLM: Bool { self == .openAICompat || self == .anthropic }
}

struct EngineProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: EngineKind
    var name: String
    var enabled: Bool = true
    /// LLM engines only.
    var baseURL: String = ""
    var model: String = ""
    var systemPromptTemplate: String = EngineProfile.defaultPromptTemplate
    /// Price per million tokens, in whatever currency the provider quotes.
    /// Zero means unknown — the per-run readout then omits cost instead of
    /// showing a made-up number. Kept per profile because prices are per model
    /// and change often.
    var inputPricePerMTok: Double = 0
    var outputPricePerMTok: Double = 0
    /// Discounted rate for prompt tokens served from the provider's cache;
    /// zero falls back to `inputPricePerMTok`.
    var cachedInputPricePerMTok: Double = 0

    /// Decoded field by field, every one optional, because this struct is
    /// persisted: the synthesized `Decodable` throws `keyNotFound` for any key
    /// a stored profile predates — it does **not** fall back to the property's
    /// default value. Adding `inputPricePerMTok` alone was enough to make every
    /// saved engine fail to decode, and the store then replaced them with a
    /// fresh default profile whose id no longer matched the keychain, i.e. "未
    /// 配置 API Key" on an app that was configured. Keep new fields decoded
    /// with `decodeIfPresent` so old data stays readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(EngineKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
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
        kind: EngineKind,
        name: String,
        enabled: Bool = true,
        baseURL: String = "",
        model: String = "",
        systemPromptTemplate: String = EngineProfile.defaultPromptTemplate,
        inputPricePerMTok: Double = 0,
        outputPricePerMTok: Double = 0,
        cachedInputPricePerMTok: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.enabled = enabled
        self.baseURL = baseURL
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

    /// Values pasted into the settings fields routinely carry a trailing
    /// newline, which the APIs reject verbatim (`invalid model ID`).
    mutating func normalize() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeDefault(kind: EngineKind) -> EngineProfile {
        switch kind {
        case .openAICompat:
            return EngineProfile(kind: .openAICompat, name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
        case .anthropic:
            return EngineProfile(kind: .anthropic, name: "Claude", baseURL: "https://api.anthropic.com", model: "claude-haiku-4-5-20251001")
        case .deepL:
            return EngineProfile(kind: .deepL, name: "DeepL")
        case .apple:
            return EngineProfile(kind: .apple, name: "Apple 翻译")
        }
    }
}

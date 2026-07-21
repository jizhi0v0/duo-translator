import Foundation

/// The wire protocol / backend a provider speaks. Formerly `EngineKind`: it
/// describes a *connection*, not a translation engine, now that a provider is
/// reused across translation cards and OCR.
enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case openAICompat
    case anthropic
    case deepL
    case apple

    var label: String {
        switch self {
        case .openAICompat: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .deepL: return "DeepL"
        case .apple: return "Apple 本地"
        }
    }

    var needsAPIKey: Bool { self != .apple }

    /// Backends configured by a Base URL + model (the ones whose detail form
    /// shows those fields, and the only ones that produce token metrics).
    var isLLM: Bool { self == .openAICompat || self == .anthropic }

    /// Every kind can translate; Apple/DeepL simply have no model to pick.
    var canTranslate: Bool { true }

    /// Kinds that can back screenshot OCR: the two vision-capable LLM dialects
    /// plus Apple's built-in Vision.
    var canOCR: Bool { self == .openAICompat || self == .anthropic || self == .apple }
}

/// A reusable connection: type + endpoint + credential. A translation card
/// (`TranslationConfig`) or the OCR selection references one by id and supplies
/// its own model, so a single provider can serve chat and OCR with different
/// models. The API key lives in the keychain, keyed by this provider's id — the
/// same keying the old per-engine profiles used, so migrated keys stay valid.
struct Provider: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: ProviderKind
    var name: String
    /// LLM kinds only; DeepL/Apple ignore it.
    var baseURL: String = ""

    /// Decoded field by field with `decodeIfPresent`, for the same reason
    /// `EngineProfile` was: this struct is persisted, and the synthesized
    /// `Decodable` throws `keyNotFound` for any key a stored value predates
    /// rather than falling back to the property default, which would make the
    /// whole store fail to decode and reset. Keep new fields optional here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    }

    /// Memberwise init, which the custom `init(from:)` above suppresses.
    init(id: UUID = UUID(), kind: ProviderKind, name: String, baseURL: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
    }

    /// Pasted values routinely carry a trailing newline, which the APIs reject
    /// verbatim (`invalid model ID`).
    mutating func normalize() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeDefault(kind: ProviderKind) -> Provider {
        switch kind {
        case .openAICompat:
            return Provider(kind: .openAICompat, name: "OpenAI", baseURL: "https://api.openai.com/v1")
        case .anthropic:
            return Provider(kind: .anthropic, name: "Claude", baseURL: "https://api.anthropic.com")
        case .deepL:
            return Provider(kind: .deepL, name: "DeepL")
        case .apple:
            return Provider(kind: .apple, name: "Apple 本地")
        }
    }

    /// The model a fresh translation card should default to for this kind, so a
    /// new card is usable without hunting for a model id.
    var defaultModel: String {
        switch kind {
        case .openAICompat: return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5-20251001"
        case .deepL, .apple: return ""
        }
    }
}

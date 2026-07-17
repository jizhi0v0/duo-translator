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

    static let defaultPromptTemplate = """
    You are a professional translation engine. Translate the user's text into {{target}}. \
    Preserve the original formatting, line breaks and markdown. \
    Output only the translation, with no explanations and no quotes around it.
    """

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

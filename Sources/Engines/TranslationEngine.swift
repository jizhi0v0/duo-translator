import Foundation

struct TranslationRequest: Sendable {
    let text: String
    /// BCP-47 code of the detected source language, if known.
    let sourceLanguage: String?
    /// BCP-47 code of the language to translate into.
    let targetLanguage: String
}

enum TranslationEvent: Sendable, Equatable {
    /// Streamed append (LLM engines).
    case delta(String)
    /// Streamed reasoning/thinking append (reasoning models).
    case reasoning(String)
    /// Whole-result replacement (non-streaming engines like DeepL / Apple).
    case replace(String)
    /// Token usage, if the provider reports it. Any field may be nil.
    case usage(TokenUsage)
    /// Model id as the provider echoed it back. Worth capturing because it is
    /// not always the one that was asked for — a gateway can quietly route to a
    /// different (usually cheaper) model, and nothing else would show it.
    case model(String)
    /// Connection timings for the request, once URLSession has collected them.
    case network(NetworkTiming)
    case done
}

/// What a provider reported about token consumption. Every field is optional:
/// most of these are extensions that only some providers send.
struct TokenUsage: Sendable, Equatable {
    var prompt: Int?
    var completion: Int?
    var total: Int?
    /// Prompt tokens served from the provider's prompt cache. Only meaningful
    /// once the shared prefix passes the provider's minimum (1024 tokens for
    /// both OpenAI and Anthropic) — with a short system prompt it stays 0.
    var cachedPrompt: Int?
    /// Prompt tokens written into the cache by this request (Anthropic bills
    /// these at a premium, so they are worth separating from a plain prompt).
    var cacheWrite: Int?
    /// Reasoning tokens billed inside `completion` (OpenAI reports these for
    /// reasoning models). They explain a slow, expensive run whose visible
    /// output is short.
    var reasoning: Int?
}

/// Where the time before the first token went — the transport, versus the model
/// actually generating. Separates "the network/proxy is slow" from "the model is
/// slow", which the single TTFT number cannot.
struct NetworkTiming: Sendable, Equatable {
    /// Request start → response headers, measured by us. Always available:
    /// URLSession's own metrics arrive at task completion, and the OpenAI
    /// dialect ends its stream by breaking on `[DONE]`, which cancels the task
    /// before they land.
    var toFirstByte: TimeInterval
    /// DNS + TCP + TLS, from `URLSessionTaskMetrics` when they do arrive. Nil
    /// on a reused connection — which is itself the answer to "why was this one
    /// slower", so `reusedConnection` is reported alongside.
    var connect: TimeInterval?
    /// Request sent → first response byte, per URLSession: the server's own
    /// queue + prefill, with the handshake excluded.
    var serverWait: TimeInterval?
    var reusedConnection: Bool?
}

enum EngineError: LocalizedError {
    case invalidURL(String)
    case missingAPIKey
    case http(status: Int, body: String)
    case decoding(String)
    case unsupported(String)
    /// Apple Translation: the language pack for this pair isn't downloaded yet.
    /// Surfaced as an in-card download prompt rather than auto-popping Apple's
    /// download sheet on every translation.
    case appleLanguagePackMissing(source: String?, target: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "无效的 API 地址：\(url)"
        case .missingAPIKey:
            return "未配置 API Key"
        case .http(let status, let body):
            return "HTTP \(status)：\(Self.compactMessage(from: body))"
        case .decoding(let detail):
            return "响应解析失败：\(detail)"
        case .unsupported(let detail):
            return detail
        case .appleLanguagePackMissing:
            return "Apple 翻译需要下载语言包"
        }
    }

    /// Pull a human-readable message out of a JSON error body when possible.
    private static func compactMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = obj["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = obj["message"] as? String { return message }
        }
        return String(body.prefix(300))
    }
}

protocol TranslationEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error>
}

import Foundation

struct TranslationRequest: Sendable {
    let text: String
    /// BCP-47 code of the detected source language, if known.
    let sourceLanguage: String?
    /// BCP-47 code of the language to translate into.
    let targetLanguage: String
}

enum TranslationEvent: Sendable {
    /// Streamed append (LLM engines).
    case delta(String)
    /// Whole-result replacement (non-streaming engines like DeepL / Apple).
    case replace(String)
    case done
}

enum EngineError: LocalizedError {
    case invalidURL(String)
    case missingAPIKey
    case http(status: Int, body: String)
    case decoding(String)
    case unsupported(String)

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

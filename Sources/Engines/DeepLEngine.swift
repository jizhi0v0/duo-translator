import Foundation

/// DeepL official REST API (non-streaming).
struct DeepLEngine: TranslationEngine {
    let profile: EngineProfile
    let apiKey: String

    var id: String { profile.id.uuidString }
    var displayName: String { profile.name }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await performTranslate(request)
                    continuation.yield(.replace(text))
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performTranslate(_ request: TranslationRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw EngineError.missingAPIKey }
        // Free-tier keys end in ":fx" and use a different host.
        let host = apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        guard let url = URL(string: "https://\(host)/v2/translate") else {
            throw EngineError.invalidURL(host)
        }

        let body: [String: Any] = [
            "text": [request.text],
            "target_lang": Self.mapTarget(request.targetLanguage),
        ]
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 60

        let (data, response) = try await HTTPClient.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.decoding("非 HTTP 响应")
        }
        switch http.statusCode {
        case 200:
            break
        case 403:
            throw EngineError.unsupported("DeepL API Key 无效。")
        case 456:
            throw EngineError.unsupported("DeepL 本月配额已用完。")
        default:
            throw EngineError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = obj["translations"] as? [[String: Any]],
              let text = translations.first?["text"] as? String else {
            throw EngineError.decoding("DeepL 响应格式异常")
        }
        return text
    }

    /// BCP-47 → DeepL target_lang.
    static func mapTarget(_ code: String) -> String {
        switch code {
        case "zh-Hans": return "ZH-HANS"
        case "zh-Hant": return "ZH-HANT"
        case "en": return "EN-US"
        case "pt": return "PT-BR"
        default: return LanguagePolicy.primary(code).uppercased()
        }
    }
}

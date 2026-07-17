import Foundation

/// Streaming Anthropic Messages API engine.
struct AnthropicEngine: TranslationEngine {
    let profile: EngineProfile
    let apiKey: String

    var id: String { profile.id.uuidString }
    var displayName: String { profile.name }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try buildRequest(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in SSEClient.events(for: urlRequest) {
                        guard let data = event.data.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        switch obj["type"] as? String {
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String,
                               !text.isEmpty {
                                continuation.yield(.delta(text))
                            }
                        case "error":
                            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
                            throw EngineError.unsupported(message)
                        default:
                            break // message_start / message_delta / ping / …
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildRequest(_ request: TranslationRequest) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw EngineError.missingAPIKey }
        var base = profile.baseURL.isEmpty ? "https://api.anthropic.com" : profile.baseURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        let path = base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        guard let url = URL(string: base + path) else {
            throw EngineError.invalidURL(profile.baseURL)
        }

        let systemPrompt = PromptTemplate.render(
            profile.systemPromptTemplate,
            target: request.targetLanguage
        )
        let body: [String: Any] = [
            "model": profile.model,
            "max_tokens": 8192,
            "stream": true,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": request.text],
            ],
        ]

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120
        return urlRequest
    }
}

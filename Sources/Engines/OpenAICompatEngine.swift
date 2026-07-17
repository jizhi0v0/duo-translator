import Foundation

/// Streaming chat-completions engine. Works for OpenAI, OpenRouter, ollama,
/// LM Studio and anything else speaking the /chat/completions dialect.
struct OpenAICompatEngine: TranslationEngine {
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
                        if event.data == "[DONE]" { break }
                        guard let data = event.data.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        for translationEvent in Self.events(fromChatFrame: obj) {
                            continuation.yield(translationEvent)
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

    /// Translate one decoded chat-completions SSE frame into events. Content and
    /// reasoning deltas plus any usage block; provider-specific reasoning keys
    /// (`reasoning_content` for DeepSeek, `reasoning` for OpenRouter) are both
    /// accepted so we stay engine-agnostic.
    static func events(fromChatFrame obj: [String: Any]) -> [TranslationEvent] {
        var events: [TranslationEvent] = []
        if let choices = obj["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.delta(content))
            }
            if let reasoning = (delta["reasoning_content"] as? String)
                ?? (delta["reasoning"] as? String), !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
        }
        if let usage = obj["usage"] as? [String: Any] {
            events.append(.usage(
                prompt: usage["prompt_tokens"] as? Int,
                completion: usage["completion_tokens"] as? Int,
                total: usage["total_tokens"] as? Int
            ))
        }
        return events
    }

    private func buildRequest(_ request: TranslationRequest) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw EngineError.missingAPIKey }
        let base = profile.baseURL.hasSuffix("/") ? String(profile.baseURL.dropLast()) : profile.baseURL
        guard let url = URL(string: base + "/chat/completions") else {
            throw EngineError.invalidURL(profile.baseURL)
        }

        let systemPrompt = PromptTemplate.render(
            profile.systemPromptTemplate,
            target: request.targetLanguage
        )
        let body: [String: Any] = [
            "model": profile.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": request.text],
            ],
        ]

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120
        return urlRequest
    }
}

enum PromptTemplate {
    static func render(_ template: String, target: String) -> String {
        template.replacingOccurrences(of: "{{target}}", with: LanguagePolicy.englishName(for: target))
    }
}

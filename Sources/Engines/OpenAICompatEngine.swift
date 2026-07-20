import Foundation

/// Streaming chat-completions engine. Works for OpenAI, OpenRouter, ollama,
/// LM Studio and anything else speaking the /chat/completions dialect.
struct OpenAICompatEngine: TranslationEngine {
    let profile: EngineProfile
    let apiKey: String

    var id: String { profile.id.uuidString }
    var displayName: String { profile.name }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await stream(request, includeUsage: true, into: continuation)
                    } catch let error as EngineError {
                        // Usage reporting is opt-in on the OpenAI dialect, and a
                        // few compatible gateways reject the field outright.
                        // Losing the token counts is acceptable; losing the
                        // translation is not, so fall back once without it.
                        guard Self.rejectedStreamOptions(error) else { throw error }
                        Log.engine.debug("引擎[\(displayName, privacy: .public)] 网关不支持 stream_options，退回无 usage 请求")
                        try await stream(request, includeUsage: false, into: continuation)
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

    /// One streamed attempt, yielding into the caller's continuation.
    private func stream(
        _ request: TranslationRequest,
        includeUsage: Bool,
        into continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try buildRequest(request, includeUsage: includeUsage)
        for try await event in SSEClient.events(
            for: urlRequest,
            onTiming: { continuation.yield(.network($0)) }
        ) {
            if event.data == "[DONE]" { break }
            guard let data = event.data.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            for translationEvent in Self.events(fromChatFrame: obj) {
                continuation.yield(translationEvent)
            }
        }
    }

    /// A 4xx that names the field — the signature of a gateway that doesn't
    /// implement `stream_options`.
    static func rejectedStreamOptions(_ error: EngineError) -> Bool {
        guard case .http(let status, let body) = error, (400..<500).contains(status) else {
            return false
        }
        return body.contains("stream_options") || body.contains("include_usage")
    }

    /// Translate one decoded chat-completions SSE frame into events. Content and
    /// reasoning deltas plus any usage block; provider-specific reasoning keys
    /// (`reasoning_content` for DeepSeek, `reasoning` for OpenRouter) are both
    /// accepted so we stay engine-agnostic.
    static func events(fromChatFrame obj: [String: Any]) -> [TranslationEvent] {
        var events: [TranslationEvent] = []
        // Every frame echoes the model; the run controller keeps the first.
        if let model = obj["model"] as? String, !model.isEmpty {
            events.append(.model(model))
        }
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
            // The `_details` blocks are optional extensions: cached prompt
            // tokens (billed at a discount) and reasoning tokens (billed inside
            // completion_tokens, so they are a breakdown, not an addition).
            let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
            let completionDetails = usage["completion_tokens_details"] as? [String: Any]
            events.append(.usage(TokenUsage(
                prompt: usage["prompt_tokens"] as? Int,
                completion: usage["completion_tokens"] as? Int,
                total: usage["total_tokens"] as? Int,
                cachedPrompt: promptDetails?["cached_tokens"] as? Int,
                reasoning: completionDetails?["reasoning_tokens"] as? Int
            )))
        }
        return events
    }

    private func buildRequest(_ request: TranslationRequest, includeUsage: Bool) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw EngineError.missingAPIKey }
        let base = profile.baseURL.hasSuffix("/") ? String(profile.baseURL.dropLast()) : profile.baseURL
        guard let url = URL(string: base + "/chat/completions") else {
            throw EngineError.invalidURL(profile.baseURL)
        }

        let systemPrompt = PromptTemplate.render(
            profile.systemPromptTemplate,
            target: request.targetLanguage
        )
        var body: [String: Any] = [
            "model": profile.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": request.text],
            ],
        ]
        if includeUsage {
            // Streaming responses carry no usage block unless asked: without
            // this the run has no token counts, and so no cost, cache or
            // reasoning breakdown either.
            body["stream_options"] = ["include_usage": true]
        }

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

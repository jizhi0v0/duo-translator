import Foundation

/// Builds and parses the single-shot vision request for an LLM OCR provider.
///
/// Deliberately separate from the translation engines' `buildRequest`: those are
/// private, streaming-only, embed the *translation* system prompt, and send
/// `content` as a plain string. OCR needs `stream:false`, an extraction prompt,
/// and a structured `content` array with the image block. Only the ~15 lines of
/// URL/header convention are duplicated from the engines, and those are stable.
enum VisionOCRRequest {
    /// Instruction shared by both providers. Kept terse and imperative so the
    /// model returns text only, not commentary or code fences.
    static let prompt = """
    Extract all text visible in this image exactly as written. Preserve the \
    reading order and line breaks. Output only the extracted text — no \
    commentary, no explanations, no markdown fences.
    """

    static func build(profile: EngineProfile, apiKey: String, base64PNG: String) throws -> URLRequest {
        switch profile.kind {
        case .openAICompat:
            return try buildOpenAI(profile: profile, apiKey: apiKey, base64PNG: base64PNG)
        case .anthropic:
            return try buildAnthropic(profile: profile, apiKey: apiKey, base64PNG: base64PNG)
        case .deepL, .apple:
            throw EngineError.unsupported("该引擎不支持图像识别")
        }
    }

    static func parse(kind: ProviderKind, data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.decoding("无法解析响应")
        }
        switch kind {
        case .openAICompat:
            let content = (obj["choices"] as? [[String: Any]])?
                .first?["message"] as? [String: Any]
            if let text = content?["content"] as? String { return text }
            throw EngineError.decoding("响应缺少文本内容")
        case .anthropic:
            if let blocks = obj["content"] as? [[String: Any]] {
                let text = blocks
                    .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined()
                if !text.isEmpty { return text }
            }
            throw EngineError.decoding("响应缺少文本内容")
        case .deepL, .apple:
            throw EngineError.unsupported("该引擎不支持图像识别")
        }
    }

    // MARK: - Per-provider builders (mirror the engines' URL/header conventions)

    private static func buildOpenAI(profile: EngineProfile, apiKey: String, base64PNG: String) throws -> URLRequest {
        let base = profile.baseURL.hasSuffix("/") ? String(profile.baseURL.dropLast()) : profile.baseURL
        guard let url = URL(string: base + "/chat/completions") else {
            throw EngineError.invalidURL(profile.baseURL)
        }
        let body: [String: Any] = [
            "model": profile.model,
            "stream": false,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url",
                     "image_url": ["url": "data:image/png;base64,\(base64PNG)"]],
                ],
            ]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        return request
    }

    private static func buildAnthropic(profile: EngineProfile, apiKey: String, base64PNG: String) throws -> URLRequest {
        var base = profile.baseURL.isEmpty ? "https://api.anthropic.com" : profile.baseURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        let path = base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        guard let url = URL(string: base + path) else {
            throw EngineError.invalidURL(profile.baseURL)
        }
        let body: [String: Any] = [
            "model": profile.model,
            "max_tokens": 4096,
            "stream": false,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png", "data": base64PNG]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        return request
    }
}

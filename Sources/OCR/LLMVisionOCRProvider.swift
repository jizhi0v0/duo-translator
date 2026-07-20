import CoreGraphics
import Foundation

/// OCR via a vision-capable LLM, reusing a configured translation engine's
/// profile (base URL / model) and its keychain API key. Single-shot: the result
/// only prefills the input box, so there's no streaming UI to feed — a plain
/// POST + one JSON parse is simpler and needs no SSE plumbing.
struct LLMVisionOCRProvider: OCRProvider {
    let profile: EngineProfile
    let apiKey: String

    /// Longest-side cap before upload. Balances OCR accuracy against token cost.
    private let maxSide = 1600

    func recognize(_ image: CGImage) async throws -> String {
        guard !apiKey.isEmpty else { throw EngineError.missingAPIKey }

        let base64 = try ImageEncoder.pngBase64(image, maxSide: maxSide)
        let request = try VisionOCRRequest.build(profile: profile, apiKey: apiKey, base64PNG: base64)

        let (data, response) = try await HTTPClient.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw EngineError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try VisionOCRRequest.parse(kind: profile.kind, data: data)
    }
}

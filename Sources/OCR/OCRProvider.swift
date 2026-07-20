import CoreGraphics

/// One way to turn a captured screenshot into text. Apple Vision is the
/// built-in, offline, free provider; a vision-capable LLM (reusing a configured
/// translation engine) is the pluggable alternative. Exactly one provider is
/// active at a time — OCR yields a single string that prefills the input box,
/// unlike translation, which fans out to several engines in parallel.
protocol OCRProvider: Sendable {
    func recognize(_ image: CGImage) async throws -> String
}

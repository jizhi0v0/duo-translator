import CoreGraphics
import Vision

/// The built-in, offline, free OCR path: Apple's Vision text recognizer. Thin
/// wrapper capturing the user's Vision settings so the factory can hand back a
/// uniform `OCRProvider` regardless of which backend is selected.
struct AppleVisionOCRProvider: OCRProvider {
    let languages: [String]
    let mergeParagraphs: Bool
    let level: VNRequestTextRecognitionLevel

    func recognize(_ image: CGImage) async throws -> String {
        try await TextRecognizer.recognize(
            image,
            languages: languages,
            mergeParagraphs: mergeParagraphs,
            level: level
        )
    }
}

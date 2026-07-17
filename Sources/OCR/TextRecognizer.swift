import Foundation
import Vision

enum TextRecognizer {
    /// OCR the image and merge line observations into readable text.
    static func recognize(
        _ image: CGImage,
        languages: [String],
        mergeParagraphs: Bool
    ) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        return try await Task.detached(priority: .userInitiated) {
            try handler.perform([request])
            let observations = request.results ?? []
            return merge(observations, mergeParagraphs: mergeParagraphs)
        }.value
    }

    /// Top-to-bottom line merge. Within a paragraph adjacent CJK lines join
    /// without a separator, Latin lines join with a space; a vertical gap
    /// larger than ~0.8 line heights starts a new paragraph.
    static func merge(
        _ observations: [VNRecognizedTextObservation],
        mergeParagraphs: Bool
    ) -> String {
        let lines: [(text: String, box: CGRect)] = observations
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return (candidate.string, observation.boundingBox)
            }
            .sorted { $0.box.midY > $1.box.midY } // Vision origin is bottom-left

        guard mergeParagraphs else {
            return lines.map(\.text).joined(separator: "\n")
        }

        var result = ""
        var previous: (text: String, box: CGRect)?
        for line in lines {
            if let previous {
                let gap = previous.box.minY - line.box.maxY
                let lineHeight = max(previous.box.height, line.box.height)
                if gap > lineHeight * 0.8 {
                    result += "\n\n"
                } else if !(endsWithCJK(previous.text) && startsWithCJK(line.text)) {
                    result += " "
                }
            }
            result += line.text
            previous = line
        }
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, // CJK punctuation + kana
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xAC00...0xD7AF,
             0xF900...0xFAFF,
             0xFF00...0xFFEF: // fullwidth forms
            return true
        default:
            return false
        }
    }

    private static func endsWithCJK(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return isCJK(scalar)
    }

    private static func startsWithCJK(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return isCJK(scalar)
    }
}

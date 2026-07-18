import Foundation

/// Fixes up text captured from other apps. Both capture paths can hand us
/// mojibake: an AX range read that splits a surrogate pair bridges the orphan
/// UTF-16 unit as U+FFFD, and a pasteboard read that races the source app's
/// staged write can decode partial data the same way.
enum CapturedTextSanitizer {
    private static let replacement = Unicode.Scalar(0xFFFD)!

    static func containsReplacementCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains(replacement)
    }

    /// Strip U+FFFD — the original bytes it stands in for are unrecoverable.
    static func sanitized(_ text: String) -> String {
        guard containsReplacementCharacter(text) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { $0 != replacement })
        return String(scalars)
    }

    /// Clamp a UTF-16 range into `text` and widen it to composed-character
    /// boundaries so it never splits a surrogate pair or combining sequence.
    /// Returns nil when the range doesn't lie within `text` at all.
    static func alignedRange(_ range: NSRange, in text: String) -> NSRange? {
        let storage = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= storage.length else {
            return nil
        }
        let clamped = NSRange(
            location: range.location,
            length: min(range.length, storage.length - range.location)
        )
        guard clamped.length > 0 else { return clamped }
        return storage.rangeOfComposedCharacterSequences(for: clamped)
    }
}

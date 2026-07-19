import Foundation
import NaturalLanguage

enum LanguagePolicy {
    /// Confidence a `languageHypotheses` guess must clear before we fall back to
    /// the recognizer's plain dominant-language pick.
    private static let confidenceFloor = 0.55

    /// Detect the dominant language of `text`, returning a BCP-47 code.
    ///
    /// Hybrid strategy. A script tally decides any *CJK-dominant* string of any
    /// length: kana and hangul are language-exclusive (they never appear in
    /// Chinese) and NLLanguageRecognizer is unreliable on CJK, so the script is
    /// the authority here. Only when Latin letters dominate does the recognizer's
    /// probability distribution decide, so a mostly-English string with a stray
    /// CJK glyph resolves to English instead of being flipped to Chinese.
    ///
    /// Note: NLLanguageRecognizer's `languageHints` are deliberately *not* used —
    /// they act as near-absolute priors (a hint of the user's pair flattens even
    /// a 99%-confidence out-of-pair French signal to English), which does more
    /// harm than the recognizer's already-strong Latin-script detection.
    static func detect(_ text: String) -> String? {
        var han = 0
        var kana = 0
        var hangul = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF:
                kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                han += 1
            case 0xAC00...0xD7AF:
                hangul += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            default:
                break
            }
        }
        let cjk = han + kana + hangul

        // CJK-dominant text: decide by script directly.
        if cjk > 0, cjk >= latin {
            if kana > 0 { return "ja" }
            if hangul > 0 { return "ko" }
            return "zh-Hans"
        }

        // Latin-script dominant (or no CJK): let the recognizer's distribution
        // decide, with a confidence floor before trusting the top guess.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))

        let best = recognizer.languageHypotheses(withMaximum: 3)
            .max { $0.value < $1.value }
        if let best, best.value >= confidenceFloor {
            return best.key.rawValue
        }
        return recognizer.dominantLanguage?.rawValue
    }

    /// Bob-style auto swap: text already in `first` → translate to `second`,
    /// anything else → translate to `first`.
    static func target(for text: String, first: String, second: String) -> String {
        guard let detected = detect(text) else { return first }
        return primary(detected) == primary(first) ? second : first
    }

    static func primary(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code))
    }

    /// English display name for prompt templates ("Simplified Chinese", …).
    static func englishName(for code: String) -> String {
        let special: [String: String] = [
            "zh-Hans": "Simplified Chinese",
            "zh-Hant": "Traditional Chinese",
        ]
        if let name = special[code] { return name }
        let english = Locale(identifier: "en")
        return english.localizedString(forIdentifier: code) ?? code
    }

    /// Localized display name for UI.
    static func localizedName(for code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

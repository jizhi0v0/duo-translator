import Foundation
import NaturalLanguage

enum LanguagePolicy {
    /// Detect the dominant language of `text`, returning a BCP-47 code.
    /// A script-range check runs first because NLLanguageRecognizer is weak on
    /// short CJK strings.
    static func detect(_ text: String) -> String? {
        var hasHan = false
        var hasKana = false
        var hasHangul = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF:
                hasKana = true
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                hasHan = true
            case 0xAC00...0xD7AF:
                hasHangul = true
            default:
                break
            }
        }
        if hasKana { return "ja" }
        if hasHangul { return "ko" }
        if hasHan { return "zh-Hans" }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
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

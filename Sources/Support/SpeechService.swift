import AVFoundation
import Combine

/// App-wide text-to-speech. One utterance at a time: starting a new one stops
/// whatever is playing, and toggling the same id stops it.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    /// Stable id of whatever is currently speaking: `"input"` for the input
    /// editor, or an `EngineRunModel.id` for a result card. `nil` when idle.
    @Published private(set) var speakingID: String?

    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance backing `speakingID`. Delegate callbacks for older,
    /// already-superseded utterances arrive asynchronously and must not clear
    /// the state of a newer one.
    private var currentUtterance: AVSpeechUtterance?

    /// BCP-47 app codes → speech synthesis locales. Detection produces the
    /// left-hand codes; voices are keyed by full locale identifiers.
    private static let voiceLocales: [String: String] = [
        "zh-Hans": "zh-CN",
        "zh-Hant": "zh-TW",
        "en": "en-US",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "fr": "fr-FR",
        "de": "de-DE",
        "es": "es-ES",
        "ru": "ru-RU",
        "pt": "pt-BR",
        "it": "it-IT",
    ]

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(id: String, text: String, languageCode: String?) {
        if speakingID == id {
            stop()
            return
        }
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.voice(for: languageCode)
        speakingID = id
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
        currentUtterance = nil
    }

    private func clear(if utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        speakingID = nil
        currentUtterance = nil
    }

    private static func voice(for code: String?) -> AVSpeechSynthesisVoice? {
        guard let code, !code.isEmpty else { return nil }
        if let locale = voiceLocales[code], let voice = AVSpeechSynthesisVoice(language: locale) {
            return voice
        }
        if let voice = AVSpeechSynthesisVoice(language: code) {
            return voice
        }
        // Fall back to any installed voice whose language shares the primary
        // subtag (e.g. "en" matching "en-GB").
        let primary = LanguagePolicy.primary(code)
        return AVSpeechSynthesisVoice.speechVoices()
            .first { LanguagePolicy.primary($0.language) == primary }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.clear(if: utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.clear(if: utterance) }
    }
}

import AppKit
import Combine

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var isPinned = false
    /// Bumped to re-focus the input editor when the panel is shown.
    @Published var focusToken = 0
    /// Transient error / hint shown under the header.
    @Published var notice: String?
    /// Language menu selections. Temporary (per session), never persisted.
    /// Populated from detection after an auto translate; editable by the user,
    /// applied only on `retranslate()`.
    @Published var selectedSource = ""
    @Published var selectedTarget = ""

    let run = TranslationRunController()

    /// Auto-detected translate (Enter / hotkey / OCR). Resets the language
    /// menus to whatever detection chose.
    func translate() {
        notice = nil
        run.start(text: inputText, settings: .shared, keychain: .shared)
        selectedSource = run.detectedLanguage ?? ""
        selectedTarget = run.targetLanguage ?? ""
    }

    /// Re-run with the current menu selections, interrupting the in-flight run.
    func retranslate() {
        notice = nil
        run.start(
            text: inputText,
            settings: .shared,
            keychain: .shared,
            sourceOverride: selectedSource.isEmpty ? nil : selectedSource,
            targetOverride: selectedTarget.isEmpty ? nil : selectedTarget
        )
        selectedSource = run.detectedLanguage ?? selectedSource
        selectedTarget = run.targetLanguage ?? selectedTarget
    }

    func swapLanguages() {
        let s = selectedSource
        selectedSource = selectedTarget
        selectedTarget = s
    }

    /// Union of the standard choices and the currently-selected codes, so a
    /// detected language outside the preset list still appears in the menus.
    func languageOptions(including extra: String...) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for code in SettingsStore.languageChoices + extra where !code.isEmpty {
            if seen.insert(code).inserted { out.append(code) }
        }
        return out
    }

    func copySelectedResult() {
        guard let selected = run.runs.first(where: { $0.id == run.selectedRunID }) ?? run.runs.first else { return }
        let text = selected.stream.fullText
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

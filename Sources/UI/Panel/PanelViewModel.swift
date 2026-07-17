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

    let run = TranslationRunController()

    func translate() {
        notice = nil
        run.start(text: inputText, settings: .shared, keychain: .shared)
    }

    func copySelectedResult() {
        guard let selected = run.runs.first(where: { $0.id == run.selectedRunID }) ?? run.runs.first else { return }
        let text = selected.stream.fullText
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var languageBadge: String {
        guard let target = run.targetLanguage else { return "自动检测" }
        let source = run.detectedLanguage.map(LanguagePolicy.localizedName(for:)) ?? "自动"
        return "\(source) → \(LanguagePolicy.localizedName(for: target))"
    }
}

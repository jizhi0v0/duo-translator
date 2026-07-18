import AppKit
import Combine
import SwiftUI

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var isPinned = false
    /// Cards the user collapsed, keyed by engine profile UUID. Session-scoped
    /// and kept across runs (run models are rebuilt every run, so this state
    /// can't live on them).
    @Published var collapsedEngineIDs: Set<String> = []
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

    /// Debounces `retranslate` so rapidly swapping / changing languages fires
    /// one translation for the final pair, not one per click.
    private var retranslateTask: Task<Void, Never>?

    /// Auto-detected translate (Enter / hotkey / OCR). Resets the language
    /// menus to whatever detection chose.
    func translate() {
        // Empty input: do nothing (and don't clear an existing notice).
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notice = nil
        run.start(text: inputText, settings: .shared, keychain: .shared)
        selectedSource = run.detectedLanguage ?? ""
        selectedTarget = run.targetLanguage ?? ""
    }

    /// Re-run with the current menu selections, interrupting the in-flight run.
    /// Debounced: a burst of language changes collapses to a single run for the
    /// final pair, avoiding rapid-fire availability checks (which could flash a
    /// spurious "download language" prompt for an already-installed pair).
    func retranslate() {
        retranslateTask?.cancel()
        retranslateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.notice = nil
            self.run.start(
                text: self.inputText,
                settings: .shared,
                keychain: .shared,
                sourceOverride: self.selectedSource.isEmpty ? nil : self.selectedSource,
                targetOverride: self.selectedTarget.isEmpty ? nil : self.selectedTarget
            )
            self.selectedSource = self.run.detectedLanguage ?? self.selectedSource
            self.selectedTarget = self.run.targetLanguage ?? self.selectedTarget
        }
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

    func collapsedBinding(for engineID: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.collapsedEngineIDs.contains(engineID) ?? false },
            set: { [weak self] collapsed in
                if collapsed {
                    self?.collapsedEngineIDs.insert(engineID)
                } else {
                    self?.collapsedEngineIDs.remove(engineID)
                }
            }
        )
    }
}

import AppKit
import Combine
import SwiftUI

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var isPinned = false
    /// Page mode: widen the panel and show one provider's output large, with a
    /// provider selector on top, instead of the stacked compact cards.
    @Published var pageMode = false
    /// Which provider is shown in page mode (engine profile UUID). Falls back to
    /// the first run when nil or absent.
    @Published var pageProviderID: String?
    /// Page mode content: true = bilingual side-by-side (原文|译文), false = 仅译文.
    @Published var pageBilingual = true
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
    /// Height available for the result list at the current window ceiling and
    /// chrome height, published by `PanelController.refit`. The result cards cap
    /// their bodies to this so the total always fits the window (tall input →
    /// shorter, internally-scrolling cards) instead of overflowing off-screen.
    @Published var resultAreaBudget: CGFloat = 400

    let run = TranslationRunController()

    /// Shared debounce channel for user-initiated translate triggers (Enter key
    /// and language swaps/changes): a burst collapses to a single run for the
    /// final input/pair instead of one run per keypress or click.
    private let debouncer = Debouncer()

    /// Debounce window for `translateDebounced` / `retranslate`. Overridable so
    /// tests can drive the coalescing quickly instead of waiting 250ms.
    var debounceDelay: Duration = .milliseconds(250)

    /// Test seam for the run start (the production path hits the network via
    /// `run.start`). When set, it replaces that call so the trigger/debounce
    /// logic can be unit-tested without engines. Nil in production.
    var runStarter: (@MainActor (_ text: String, _ source: String?, _ target: String?) -> Void)?

    /// Starts a translation run — through the injected `runStarter` if present,
    /// otherwise the real engine controller.
    private func startRun(text: String, source: String?, target: String?) {
        if let runStarter {
            runStarter(text, source, target)
            return
        }
        run.start(
            text: text, settings: .shared, keychain: .shared,
            sourceOverride: source, targetOverride: target
        )
    }

    /// Auto-detected translate (hotkey / OCR auto-translate). Resets the language
    /// menus to whatever detection chose. Fires immediately; cancels any pending
    /// debounced run so it can't fire a duplicate right after.
    func translate() {
        debouncer.cancel()
        // Empty input: do nothing (and don't clear an existing notice).
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notice = nil
        startRun(text: inputText, source: nil, target: nil)
        selectedSource = run.detectedLanguage ?? ""
        selectedTarget = run.targetLanguage ?? ""
    }

    /// Enter-key translate, debounced so a double-tap or held Return fires one
    /// run for the final input rather than restarting the engines repeatedly.
    func translateDebounced() {
        debouncer.schedule(after: debounceDelay) { [weak self] in
            self?.translate()
        }
    }

    /// Re-run with the current menu selections, interrupting the in-flight run.
    /// Debounced: a burst of language changes collapses to a single run for the
    /// final pair, avoiding rapid-fire availability checks (which could flash a
    /// spurious "download language" prompt for an already-installed pair).
    func retranslate() {
        debouncer.schedule(after: debounceDelay) { [weak self] in
            guard let self else { return }
            self.notice = nil
            self.startRun(
                text: self.inputText,
                source: self.selectedSource.isEmpty ? nil : self.selectedSource,
                target: self.selectedTarget.isEmpty ? nil : self.selectedTarget
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

/// Coalesces a burst of calls into a single trailing action: each `schedule`
/// cancels the previous pending one, so only the last call within `delay` runs.
/// Factored out of `PanelViewModel` so the debounce is unit-testable (with a
/// short delay) independently of what it triggers.
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

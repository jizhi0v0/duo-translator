import Foundation
import Combine

/// One engine's live output within a translation run.
@MainActor
final class EngineRunModel: ObservableObject, Identifiable {
    enum RunState: Equatable {
        case streaming
        case done(seconds: Double)
        case failed(message: String)
    }

    let id: String
    let name: String
    let kind: EngineKind
    let stream = StreamingTextModel()
    /// Reasoning/thinking output (reasoning models only).
    let thinkingStream = StreamingTextModel()
    @Published var state: RunState = .streaming
    /// Set once the engine emits any reasoning; gates the collapsible section.
    @Published var hasThinking = false
    /// User-toggled disclosure state; thinking starts collapsed.
    @Published var thinkingExpanded = false
    /// Token usage parsed from the stream, if the provider reported it.
    var usage: (prompt: Int?, completion: Int?, total: Int?)?

    init(id: String, name: String, kind: EngineKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// Fans one translation request out to every enabled engine and manages
/// cancellation. Each engine streams into its own `EngineRunModel`.
@MainActor
final class TranslationRunController: ObservableObject {
    @Published private(set) var runs: [EngineRunModel] = []
    @Published var selectedRunID: String?
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var targetLanguage: String?

    private var tasks: [Task<Void, Never>] = []

    /// `sourceOverride` / `targetOverride` come from the panel's language menus
    /// (a manual re-translate); when nil the languages are auto-detected.
    func start(
        text: String,
        settings: SettingsStore,
        keychain: KeychainStore,
        sourceOverride: String? = nil,
        targetOverride: String? = nil
    ) {
        cancelAll()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let detected = sourceOverride ?? LanguagePolicy.detect(trimmed)
        let target = targetOverride ?? LanguagePolicy.target(
            for: trimmed,
            first: settings.firstLanguage,
            second: settings.secondLanguage
        )
        detectedLanguage = detected
        targetLanguage = target

        let request = TranslationRequest(text: trimmed, sourceLanguage: detected, targetLanguage: target)
        let profiles = settings.enabledProfiles
        let engines = EngineFactory.makeEngines(settings: settings, keychain: keychain)

        guard !engines.isEmpty else {
            let run = EngineRunModel(id: "none", name: "未配置引擎", kind: .openAICompat)
            run.state = .failed(message: "请在设置中启用并配置至少一个翻译引擎。")
            runs = [run]
            selectedRunID = run.id
            return
        }

        runs = zip(profiles, engines).map { EngineRunModel(id: $1.id, name: $1.displayName, kind: $0.kind) }
        if selectedRunID == nil || !runs.contains(where: { $0.id == selectedRunID }) {
            selectedRunID = runs.first?.id
        }

        let inputChars = trimmed.count
        tasks = zip(engines, runs).map { engine, run in
            Task { [weak run] in
                let started = Date()
                do {
                    for try await event in engine.translate(request) {
                        guard let run else { return }
                        switch event {
                        case .delta(let chunk):
                            run.stream.append(chunk)
                        case .reasoning(let chunk):
                            run.hasThinking = true
                            run.thinkingStream.append(chunk)
                        case .replace(let text):
                            run.stream.replaceAll(text)
                        case .usage(let prompt, let completion, let total):
                            run.usage = (prompt, completion, total)
                        case .done:
                            break
                        }
                    }
                    guard let run else { return }
                    run.stream.finish()
                    run.thinkingStream.finish()
                    let seconds = Date().timeIntervalSince(started)
                    run.state = .done(seconds: seconds)
                    Self.record(run, source: detected, target: target,
                                inputChars: inputChars, duration: seconds, status: .success)
                } catch is CancellationError {
                    Log.engine.debug("run cancelled, connection torn down")
                    if let run {
                        Self.record(run, source: detected, target: target, inputChars: inputChars,
                                    duration: Date().timeIntervalSince(started), status: .cancelled)
                    }
                } catch {
                    guard let run else { return }
                    run.stream.finish()
                    run.thinkingStream.finish()
                    run.state = .failed(message: error.localizedDescription)
                    Self.record(run, source: detected, target: target, inputChars: inputChars,
                                duration: Date().timeIntervalSince(started), status: .failed)
                }
            }
        }
    }

    /// Append one metadata-only record to the stats store (no text bodies).
    private static func record(
        _ run: EngineRunModel,
        source: String?,
        target: String,
        inputChars: Int,
        duration: Double,
        status: RecordStatus
    ) {
        StatsStore.shared.add(TranslationRecord(
            date: Date(),
            engineKind: run.kind.rawValue,
            engineName: run.name,
            source: source,
            target: target,
            inputChars: inputChars,
            outputChars: run.stream.fullText.count,
            promptTokens: run.usage?.prompt,
            completionTokens: run.usage?.completion,
            totalTokens: run.usage?.total,
            durationSeconds: duration,
            status: status
        ))
    }

    func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
        // The Apple bridge's continuation doesn't observe task cancellation.
        AppleTranslationBridge.shared.cancelPending()
    }

    func clear() {
        cancelAll()
        runs = []
        detectedLanguage = nil
        targetLanguage = nil
    }
}

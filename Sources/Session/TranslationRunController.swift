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
    let stream = StreamingTextModel()
    @Published var state: RunState = .streaming

    init(id: String, name: String) {
        self.id = id
        self.name = name
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

    func start(text: String, settings: SettingsStore, keychain: KeychainStore) {
        cancelAll()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let detected = LanguagePolicy.detect(trimmed)
        let target = LanguagePolicy.target(
            for: trimmed,
            first: settings.firstLanguage,
            second: settings.secondLanguage
        )
        detectedLanguage = detected
        targetLanguage = target

        let request = TranslationRequest(text: trimmed, sourceLanguage: detected, targetLanguage: target)
        let engines = EngineFactory.makeEngines(settings: settings, keychain: keychain)

        guard !engines.isEmpty else {
            let run = EngineRunModel(id: "none", name: "未配置引擎")
            run.state = .failed(message: "请在设置中启用并配置至少一个翻译引擎。")
            runs = [run]
            selectedRunID = run.id
            return
        }

        runs = engines.map { EngineRunModel(id: $0.id, name: $0.displayName) }
        if selectedRunID == nil || !runs.contains(where: { $0.id == selectedRunID }) {
            selectedRunID = runs.first?.id
        }

        tasks = zip(engines, runs).map { engine, run in
            Task { [weak run] in
                let started = Date()
                do {
                    for try await event in engine.translate(request) {
                        guard let run else { return }
                        switch event {
                        case .delta(let chunk):
                            run.stream.append(chunk)
                        case .replace(let text):
                            run.stream.replaceAll(text)
                        case .done:
                            break
                        }
                    }
                    guard let run else { return }
                    run.stream.finish()
                    run.state = .done(seconds: Date().timeIntervalSince(started))
                } catch is CancellationError {
                    // silent
                } catch {
                    guard let run else { return }
                    run.stream.finish()
                    run.state = .failed(message: error.localizedDescription)
                }
            }
        }
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

import Foundation
import Combine

/// One engine's live output within a translation run.
@MainActor
final class EngineRunModel: ObservableObject, Identifiable {
    enum RunState: Equatable {
        case streaming
        case done(seconds: Double)
        case failed(message: String)
        /// Apple Translation: language pack not downloaded; the card offers an
        /// explicit download button that carries this pair.
        case needsAppleDownload(source: String?, target: String)

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    let id: String
    let name: String
    let kind: EngineKind
    let stream = StreamingTextModel()
    /// Reasoning/thinking output (reasoning models only).
    let thinkingStream = StreamingTextModel()
    @Published var state: RunState = .streaming
    /// Flips true on the first body chunk. While false and still streaming, the
    /// card shows a compact loading placeholder instead of an empty text view
    /// sized from the previous run — so a slow engine doesn't reserve a tall
    /// blank block above a fast one's result.
    @Published var hasContent = false
    /// Set once the engine emits any reasoning; gates the collapsible section.
    @Published var hasThinking = false
    /// User-toggled disclosure state; thinking starts collapsed.
    @Published var thinkingExpanded = false
    /// Token usage parsed from the stream, if the provider reported it.
    var usage: (prompt: Int?, completion: Int?, total: Int?)?
    /// First-token latency + throughput, filled in when the run finishes.
    /// Shown only for LLM engines (see `EngineKind.isLLM`).
    @Published var metrics: RunMetrics?

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
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var targetLanguage: String?
    /// Bumped once per `start()`. The panel resets its height on this, not on
    /// `$runs`, so a single-engine `retry` doesn't snap the window back.
    @Published private(set) var runGeneration = 0

    private var tasks: [String: Task<Void, Never>] = [:]
    private var lastRequest: TranslationRequest?

    /// Source text of the most recent run, for the bilingual reader window.
    var lastSourceText: String? { lastRequest?.text }

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
        lastRequest = request
        let profiles = settings.enabledProfiles
        let engines = EngineFactory.makeEngines(settings: settings, keychain: keychain)

        runGeneration += 1

        guard !engines.isEmpty else {
            let run = EngineRunModel(id: "none", name: "未配置引擎", kind: .openAICompat)
            run.state = .failed(message: "请在设置中启用并配置至少一个翻译引擎。")
            runs = [run]
            return
        }

        runs = zip(profiles, engines).map { EngineRunModel(id: $1.id, name: $1.displayName, kind: $0.kind) }
        for (engine, run) in zip(engines, runs) {
            launch(engine: engine, run: run, request: request)
        }
    }

    /// Cancel and restart a single engine without touching the others. The run
    /// model is replaced in place (same id) so the card row stays stable while
    /// the streaming views rebind to fresh stream models.
    func retry(runID: String) {
        guard let request = lastRequest,
              let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        let old = runs[index]
        tasks[runID]?.cancel()
        tasks[runID] = nil
        if old.kind == .apple {
            // The Apple bridge's continuation doesn't observe task cancellation.
            AppleTranslationBridge.shared.cancelPending()
        }

        guard let profile = SettingsStore.shared.enabledProfiles.first(where: { $0.id.uuidString == runID }) else { return }
        let engine = EngineFactory.makeEngine(profile: profile, keychain: .shared)
        let fresh = EngineRunModel(id: old.id, name: old.name, kind: old.kind)
        runs[index] = fresh
        launch(engine: engine, run: fresh, request: request)
    }

    /// Explicit user action from the Apple card's "下载语言包" button: download
    /// the pack (Apple's system sheet appears once), then re-run that engine.
    func downloadAppleLanguagePack(runID: String, source: String?, target: String) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].state = .streaming // show progress while the sheet is up
        Task { @MainActor in
            do {
                try await AppleTranslationBridge.shared.prepareDownload(source: source, target: target)
                retry(runID: runID)
            } catch is CancellationError {
                setNeedsDownload(runID: runID, source: source, target: target)
            } catch {
                setNeedsDownload(runID: runID, source: source, target: target)
            }
        }
    }

    private func setNeedsDownload(runID: String, source: String?, target: String) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].state = .needsAppleDownload(source: source, target: target)
    }

    private func launch(engine: any TranslationEngine, run: EngineRunModel, request: TranslationRequest) {
        let detected = request.sourceLanguage
        let target = request.targetLanguage
        let inputChars = request.text.count
        tasks[run.id] = Task { [weak run] in
            let started = Date()
            // First token of any kind (content or reasoning): reasoning models
            // emit their chain-of-thought before the translation, and that is
            // still "time to first token" from the user's point of view.
            var firstTokenAt: Date?
            func markFirstToken() { if firstTokenAt == nil { firstTokenAt = Date() } }
            do {
                for try await event in engine.translate(request) {
                    guard let run else { return }
                    switch event {
                    case .delta(let chunk):
                        markFirstToken()
                        run.hasContent = true
                        run.stream.append(chunk)
                    case .reasoning(let chunk):
                        markFirstToken()
                        run.hasThinking = true
                        run.thinkingStream.append(chunk)
                    case .replace(let text):
                        markFirstToken()
                        run.hasContent = true
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
                if run.kind.isLLM {
                    run.metrics = RunMetrics.make(
                        total: seconds,
                        ttft: firstTokenAt.map { $0.timeIntervalSince(started) },
                        outputChars: run.stream.fullText.count,
                        promptTokens: run.usage?.prompt,
                        completionTokens: run.usage?.completion,
                        totalTokens: run.usage?.total
                    )
                }
                Log.engine.debug("引擎[\(run.name, privacy: .public)] done \(String(format: "%.1f", seconds), privacy: .public)s, \(run.stream.fullText.count, privacy: .public) 字")
                run.state = .done(seconds: seconds)
                Self.record(run, source: detected, target: target,
                            inputChars: inputChars, duration: seconds, status: .success)
            } catch is CancellationError {
                Log.engine.debug("run cancelled, connection torn down")
                if let run {
                    Self.record(run, source: detected, target: target, inputChars: inputChars,
                                duration: Date().timeIntervalSince(started), status: .cancelled)
                }
            } catch let error as EngineError {
                guard let run else { return }
                run.stream.finish()
                run.thinkingStream.finish()
                if case .appleLanguagePackMissing(let source, let target) = error {
                    // Not a failure — a pending user action. Don't log it as one.
                    run.state = .needsAppleDownload(source: source, target: target)
                } else {
                    run.state = .failed(message: error.localizedDescription)
                    Self.record(run, source: detected, target: target, inputChars: inputChars,
                                duration: Date().timeIntervalSince(started), status: .failed)
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
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        // The Apple bridge's continuation doesn't observe task cancellation.
        AppleTranslationBridge.shared.cancelPending()
    }

    func clear() {
        cancelAll()
        runs = []
        detectedLanguage = nil
        targetLanguage = nil
    }

    /// UI-test seam (driven by the `-uiTest` launch): replace the runs with
    /// `count` cards carrying `text`, so tests can exercise result-area sizing
    /// without a live translation. `streaming` leaves the cards in their initial
    /// no-content loading state, which covers immediate page-mode switching.
    /// Inert unless called from the UI-test launch path.
    func uiTestSeedResults(count: Int, text: String, streaming: Bool = false) {
        cancelAll()
        let names = ["OpenAI", "Apple 翻译", "DeepL"]
        runs = (0..<max(count, 1)).map { i in
            let run = EngineRunModel(id: "uitest-\(i)", name: names[i % names.count], kind: .openAICompat)
            if !streaming {
                run.stream.replaceAll(text)
                run.stream.finish()
                run.hasContent = true
                // Seed a performance readout so the header gauge / popover has
                // something deterministic to show under test.
                run.metrics = RunMetrics.make(
                    total: 1.2, ttft: 0.3, outputChars: text.count,
                    promptTokens: 40, completionTokens: 120, totalTokens: 160
                )
                run.state = .done(seconds: 0.5)
            }
            return run
        }
        detectedLanguage = "en"
        targetLanguage = "zh-Hans"
    }

    /// UI-test seam: flip the current cards back to their no-content loading
    /// state **in place** — same run models, their finished result text left in
    /// the stream. This reproduces the reported bug directly: the card is in the
    /// placeholder state while a tall body height lingers from the last result,
    /// and the placeholder must still render compact. (Reusing the models means
    /// the streaming view doesn't rebind/reset, so nothing external shrinks the
    /// body — only the card's own placeholder rule can.)
    func uiTestReseedStreaming() {
        cancelAll()
        runGeneration += 1
        for run in runs {
            run.hasContent = false
            run.state = .streaming
        }
    }

    /// UI-test-only deterministic stream. It waits long enough for automation
    /// to enter page mode, then emits several chunks so the test can prove the
    /// AppKit reader receives deltas after the mode switch and reaches the tail.
    func uiTestStreamFirstResult(text: String) {
        guard let run = runs.first, !text.isEmpty else { return }
        let chunks = Self.uiTestChunks(text, count: 6)
        tasks[run.id] = Task { @MainActor [weak run] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let run else { return }
            for chunk in chunks {
                guard !Task.isCancelled else { return }
                run.hasContent = true
                run.stream.append(chunk)
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            run.stream.finish()
            run.state = .done(seconds: 1.5)
        }
    }

    private static func uiTestChunks(_ text: String, count: Int) -> [String] {
        let size = max(1, Int(ceil(Double(text.count) / Double(max(count, 1)))))
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}

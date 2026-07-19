import SwiftUI
import Translation

/// Apple's Translation framework has no imperative API — a `TranslationSession`
/// is only vended to a SwiftUI `.translationTask` closure. This bridge lives on
/// an invisible 1×1 view inside the panel; the engine enqueues a request, the
/// bridge changes the task configuration to wake the closure, and the closure
/// resolves the pending continuation.
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    /// A job waiting for a `TranslationSession` to be vended by the hidden view.
    private enum Job {
        /// Translate this text and resume with the result.
        case translate(TranslationRequest, CheckedContinuation<String, Error>)
        /// Download the language pack for the configured pair (shows Apple's
        /// download sheet), resuming when it finishes.
        case prepare(source: String?, target: String, CheckedContinuation<Void, Error>)
    }

    @Published var configuration: TranslationSession.Configuration?
    private var pending: Job?

    private let availability = LanguageAvailability()
    /// Pairs confirmed installed. Once a pair is known good we skip the async
    /// availability check — `LanguageAvailability.status` is conservative and
    /// reports `.supported` (not `.installed`) for packs a real session can
    /// already translate with, flashing a bogus download prompt for a pack
    /// that's actually present. A pair is confirmed either by `status` or, more
    /// authoritatively, by a session that translated/prepared successfully.
    /// Persisted across launches so the prompt appears at most once per pair.
    private var installedPairs: Set<String>
    private let installedDefaultsKey = "AppleTranslation.confirmedInstalledPairs"

    private init() {
        installedPairs = Set(UserDefaults.standard.stringArray(forKey: installedDefaultsKey) ?? [])
    }

    /// Record a pair as installed and persist it. `source == nil` pairs are not
    /// cached (an unknown source always short-circuits to "installed" anyway).
    private func markInstalled(source: String?, target: String) {
        guard let source else { return }
        guard installedPairs.insert("\(source)>\(target)").inserted else { return }
        UserDefaults.standard.set(Array(installedPairs), forKey: installedDefaultsKey)
    }

    /// Whether the pack for this pair is already installed, so the caller can
    /// decide to translate directly vs. prompt for a download — without ever
    /// triggering Apple's download sheet.
    func isInstalled(source: String?, target: String) async -> Bool {
        guard let source else { return true } // unknown source: let translate try
        let key = "\(source)>\(target)"
        if installedPairs.contains(key) { return true }
        let status = await availability.status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed:
            markInstalled(source: source, target: target)
            return true
        default:
            return false
        }
    }

    func translate(_ request: TranslationRequest) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            start(job: .translate(request, continuation),
                  source: request.sourceLanguage, target: request.targetLanguage)
        }
    }

    /// Trigger the system language-pack download for a pair. Called only from an
    /// explicit user action (the in-card "下载语言包" button), never automatically.
    func prepareDownload(source: String?, target: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            start(job: .prepare(source: source, target: target, continuation), source: source, target: target)
        }
    }

    /// Queue a job and poke the configuration so the hidden view's
    /// `.translationTask` closure wakes up. Only one job is in flight; a newer
    /// one supersedes the old.
    private func start(job: Job, source: String?, target: String) {
        cancelPending()
        pending = job
        let sourceLang = source.map { Locale.Language(identifier: $0) }
        let newConfig = TranslationSession.Configuration(
            source: sourceLang, target: Locale.Language(identifier: target)
        )
        if configuration?.source == newConfig.source, configuration?.target == newConfig.target {
            // Same pair as last time — assignment wouldn't re-trigger the task.
            configuration?.invalidate()
        } else {
            configuration = newConfig
        }
    }

    /// Called from the hidden view's `.translationTask` closure.
    func handle(_ session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil
        switch job {
        case .translate(let request, let continuation):
            do {
                let response = try await session.translate(request.text)
                // A successful translation is authoritative proof the pack is
                // installed, even if `status` earlier claimed otherwise.
                markInstalled(source: request.sourceLanguage, target: request.targetLanguage)
                continuation.resume(returning: response.targetText)
            } catch {
                continuation.resume(throwing: error)
            }
        case .prepare(let source, let target, let continuation):
            do {
                try await session.prepareTranslation()
                markInstalled(source: source, target: target)
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancelPending() {
        guard let job = pending else { return }
        pending = nil
        switch job {
        case .translate(_, let continuation): continuation.resume(throwing: CancellationError())
        case .prepare(_, _, let continuation): continuation.resume(throwing: CancellationError())
        }
    }
}

/// Invisible host that owns the `translationTask`. Must sit in a visible
/// window's hierarchy (the language-pack download sheet anchors to it).
struct AppleTranslationHostView: View {
    @ObservedObject private var bridge = AppleTranslationBridge.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.handle(session)
            }
    }
}

struct AppleTranslationEngine: TranslationEngine {
    let profile: EngineProfile

    var id: String { profile.id.uuidString }
    var displayName: String { profile.name }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    // Preflight: if the pack isn't installed, surface a download
                    // prompt in the card instead of auto-popping Apple's sheet
                    // on every translation.
                    let installed = await AppleTranslationBridge.shared.isInstalled(
                        source: request.sourceLanguage, target: request.targetLanguage
                    )
                    guard installed else {
                        continuation.finish(throwing: EngineError.appleLanguagePackMissing(
                            source: request.sourceLanguage, target: request.targetLanguage
                        ))
                        return
                    }
                    let text = try await AppleTranslationBridge.shared.translate(request)
                    continuation.yield(.replace(text))
                    continuation.yield(.done)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: EngineError.unsupported(
                        "Apple 翻译失败：\(error.localizedDescription)"
                    ))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

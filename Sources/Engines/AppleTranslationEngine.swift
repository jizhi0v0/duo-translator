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

    @Published var configuration: TranslationSession.Configuration?
    private var pending: (request: TranslationRequest, continuation: CheckedContinuation<String, Error>)?

    func translate(_ request: TranslationRequest) async throws -> String {
        // Only one in-flight request; a newer one supersedes the old.
        if let old = pending {
            pending = nil
            old.continuation.resume(throwing: CancellationError())
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending = (request, continuation)
            let source = request.sourceLanguage.map { Locale.Language(identifier: $0) }
            let target = Locale.Language(identifier: request.targetLanguage)
            let newConfig = TranslationSession.Configuration(source: source, target: target)
            if configuration?.source == newConfig.source, configuration?.target == newConfig.target {
                // Same pair as last time — assignment wouldn't re-trigger the task.
                configuration?.invalidate()
            } else {
                configuration = newConfig
            }
        }
    }

    /// Called from the hidden view's `.translationTask` closure.
    func handle(_ session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil
        do {
            let response = try await session.translate(job.request.text)
            job.continuation.resume(returning: response.targetText)
        } catch {
            job.continuation.resume(throwing: error)
        }
    }

    func cancelPending() {
        if let old = pending {
            pending = nil
            old.continuation.resume(throwing: CancellationError())
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
                    let text = try await AppleTranslationBridge.shared.translate(request)
                    continuation.yield(.replace(text))
                    continuation.yield(.done)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: EngineError.unsupported(
                        "Apple 翻译失败：\(error.localizedDescription)（可能需要在系统设置中下载语言包）"
                    ))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

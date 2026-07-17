import Foundation

/// Append-only text buffer with coalesced flushing — the anti-jank core.
/// Engine deltas land in `pending`; at most every 33ms the pending suffix is
/// handed to the attached view exactly once, so the NSTextView only ever
/// receives appends, never full-document rewrites.
@MainActor
final class StreamingTextModel {
    private(set) var fullText = ""
    private var pending = ""
    private var flushScheduled = false
    private var generation = 0

    /// Set by the attached text view. Called on the main actor with the chunk
    /// to append.
    var onAppend: ((String) -> Void)?
    /// Called when the buffer is reset (new run / replaceAll).
    var onReset: (() -> Void)?

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        pending += chunk
        scheduleFlush()
    }

    /// Non-streaming engines deliver the whole result at once.
    func replaceAll(_ text: String) {
        pending = ""
        fullText = ""
        onReset?()
        append(text)
    }

    func reset() {
        pending = ""
        fullText = ""
        generation += 1
        onReset?()
    }

    /// Flush whatever is pending immediately (stream ended).
    func finish() {
        flushNow()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
            guard let self, self.generation == expected else {
                self?.flushScheduled = false
                return
            }
            self.flushNow()
        }
    }

    private func flushNow() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let chunk = pending
        pending = ""
        fullText += chunk
        onAppend?(chunk)
    }
}

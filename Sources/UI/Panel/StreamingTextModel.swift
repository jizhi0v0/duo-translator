import Foundation

/// Append-only text buffer with a paced reveal — the anti-jank core.
///
/// Engine deltas land in `pending` and are handed to the attached view one
/// slice per frame, each slice sized so the *current* backlog drains over a
/// fixed horizon. That makes the reveal rate follow the engine's rate without
/// following its burstiness: a fast engine (or a non-streaming one that returns
/// everything at once) reveals more per frame instead of dumping a paragraph in
/// a single layout pass, and a slow one still trickles evenly. The attached
/// view only ever receives appends, never full-document rewrites.
///
/// Steady frame-sized appends are also what keeps the result card's height in
/// step with its text: the card re-measures per append, so a 33ms burst that
/// wrapped three new lines at once is what used to make the height visibly lag
/// behind the glyphs.
@MainActor
final class StreamingTextModel {
    /// Everything received so far, including text not yet revealed. Copy,
    /// speech and stats read this — they must never lose a tail that is still
    /// being typed out.
    private(set) var fullText = ""
    /// The revealed prefix of `fullText` — exactly what the attached view holds.
    /// Views project from this, not `fullText`, so every reader stays on the
    /// same paced timeline.
    private(set) var revealedText = ""
    private var pending = ""
    private var timer: Timer?
    private var generation = 0
    /// Frames left before the current backlog should be fully revealed.
    private var framesLeft = 0
    /// Set when the engine is done: the remaining backlog is then revealed over
    /// a shorter horizon, so the tail doesn't drag on past the "done" badge.
    private var finishing = false

    /// Set by the attached text view. Called on the main actor with the chunk
    /// to append.
    var onAppend: ((String) -> Void)?
    /// Called when the buffer is reset (new run / replaceAll).
    var onReset: (() -> Void)?

    /// Reveal cadence: one slice per frame.
    private static let tick: TimeInterval = 1.0 / 60
    /// Whatever is buffered is spread across this window. Long enough to smooth
    /// out a bursty stream, short enough that the text never feels held back.
    private static let horizon: TimeInterval = 0.25
    /// Tighter horizon once the engine has finished, so the last slices land
    /// promptly instead of typing on after the run is visibly done.
    private static let finishingHorizon: TimeInterval = 0.08

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        fullText += chunk
        pending += chunk
        // New text pushes the deadline back out: the whole backlog, old tail
        // included, is re-spread over a fresh horizon.
        framesLeft = StreamingPacer.frames(horizon: Self.horizon, tick: Self.tick)
        startPacing()
    }

    /// Non-streaming engines deliver the whole result at once. It is still
    /// revealed at the paced rate, so their output reads like every other
    /// engine's instead of appearing in one jump.
    func replaceAll(_ text: String) {
        clear()
        onReset?()
        append(text)
    }

    func reset() {
        clear()
        generation += 1
        onReset?()
    }

    /// The engine stopped producing. `fullText` is already complete — only the
    /// visible tail is still catching up, and it now does so against the tighter
    /// finishing deadline.
    func finish() {
        finishing = true
        framesLeft = min(
            framesLeft,
            StreamingPacer.frames(horizon: Self.finishingHorizon, tick: Self.tick)
        )
        if pending.isEmpty { stopPacing() }
    }

    private func clear() {
        stopPacing()
        pending = ""
        fullText = ""
        revealedText = ""
        finishing = false
        framesLeft = 0
    }

    private func startPacing() {
        guard timer == nil else { return }
        let expected = generation
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == expected else { return }
                self.revealSlice()
            }
        }
        // .common keeps the visible stream rendering during window movement.
        // The panel freezes geometry and scroll offsets separately, so text can
        // continue appearing without moving the reader's viewport.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // First slice now: waiting a frame would show an empty card for longer
        // than the engine's own latency.
        revealSlice()
    }

    private func stopPacing() {
        timer?.invalidate()
        timer = nil
    }

    private func revealSlice() {
        guard !pending.isEmpty else {
            stopPacing()
            return
        }
        let slice = String(pending.prefix(
            StreamingPacer.sliceLength(backlog: pending.count, framesLeft: framesLeft)
        ))
        framesLeft = max(1, framesLeft - 1)
        pending.removeFirst(slice.count)
        revealedText += slice
        onAppend?(slice)
        if pending.isEmpty { stopPacing() }
    }
}

/// The reveal-rate rule, factored out so it can be unit-tested without a
/// running clock.
enum StreamingPacer {
    /// Characters to reveal this frame: the backlog spread over the frames left
    /// before its deadline, and never less than one character (so a trickle of
    /// one-token deltas still moves every frame rather than stalling).
    ///
    /// Dividing by the *remaining* frames rather than the full horizon is what
    /// makes the deadline real. Recomputing against the full horizon every frame
    /// looks the same at first but decays exponentially — the last handful of
    /// characters then trickle out one per frame, long after the horizon, which
    /// reads as the text stalling just before it finishes.
    static func sliceLength(backlog: Int, framesLeft: Int) -> Int {
        guard backlog > 0 else { return 0 }
        let frames = max(1, framesLeft)
        return max(1, Int((Double(backlog) / Double(frames)).rounded(.up)))
    }

    /// Frames in a reveal window, at the given tick.
    static func frames(horizon: TimeInterval, tick: TimeInterval) -> Int {
        max(1, Int((horizon / tick).rounded()))
    }
}

import XCTest
@testable import DuoTranslator

/// Behavioral tests for the Enter/retranslate debounce, driven through the
/// injected `runStarter` seam so no real engine/network runs. Guards that a
/// burst of triggers collapses to a single run and that the latest input wins —
/// exercised for empty, short, and changing input.
@MainActor
final class PanelViewModelTests: XCTestCase {

    func testEachPageModeEntryGetsFreshPresentationIdentity() {
        let vm = PanelViewModel()
        let initial = vm.pageModePresentationID

        vm.togglePageMode()
        XCTAssertTrue(vm.pageMode)
        XCTAssertEqual(vm.pageModePresentationID, initial + 1)

        vm.togglePageMode()
        XCTAssertFalse(vm.pageMode)
        XCTAssertEqual(vm.pageModePresentationID, initial + 1)

        vm.togglePageMode()
        XCTAssertTrue(vm.pageMode)
        XCTAssertEqual(vm.pageModePresentationID, initial + 2)
    }

    func testEnterDebounceCoalescesBurstToSingleRun() async {
        let vm = PanelViewModel()
        vm.debounceDelay = .milliseconds(20)
        var runs: [String] = []
        vm.runStarter = { text, _, _ in runs.append(text) }
        vm.inputText = "hello"

        for _ in 0..<6 { vm.translateDebounced() }
        XCTAssertTrue(runs.isEmpty, "nothing should fire before the debounce window elapses")

        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(runs, ["hello"], "a burst of Enter presses must fire exactly one run")
    }

    func testLatestInputWinsWithinDebounceWindow() async {
        let vm = PanelViewModel()
        vm.debounceDelay = .milliseconds(30)
        var runs: [String] = []
        vm.runStarter = { text, _, _ in runs.append(text) }

        vm.inputText = "first"
        vm.translateDebounced()
        vm.inputText = "second"
        vm.translateDebounced()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runs, ["second"])
    }

    func testDebouncedTranslateSkipsEmptyInput() async {
        let vm = PanelViewModel()
        vm.debounceDelay = .milliseconds(20)
        var count = 0
        vm.runStarter = { _, _, _ in count += 1 }
        vm.inputText = "   \n  "
        vm.notice = "keep"

        vm.translateDebounced()
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(count, 0, "whitespace-only input must not start a run")
        XCTAssertEqual(vm.notice, "keep", "the empty-input guard returns before clearing the notice")
    }

    func testImmediateTranslateCancelsPendingDebounce() async {
        // The hotkey/OCR immediate path runs now and must cancel a pending
        // debounced run so the translation doesn't fire twice.
        let vm = PanelViewModel()
        vm.debounceDelay = .milliseconds(30)
        var count = 0
        vm.runStarter = { _, _, _ in count += 1 }
        vm.inputText = "hi"

        vm.translateDebounced()
        vm.translate() // immediate; cancels the pending one

        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(count, 1)
    }

    func testRetranslateUsesSelectedLanguageOverrides() async {
        let vm = PanelViewModel()
        vm.debounceDelay = .milliseconds(20)
        var captured: (String, String?, String?)?
        vm.runStarter = { text, source, target in captured = (text, source, target) }
        vm.inputText = "hola"
        vm.selectedSource = "es"
        vm.selectedTarget = "en"

        vm.retranslate()
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(captured?.0, "hola")
        XCTAssertEqual(captured?.1, "es")
        XCTAssertEqual(captured?.2, "en")
    }
}

/// Unit tests for the debounce primitive itself.
@MainActor
final class DebouncerTests: XCTestCase {

    func testFiresOnceForABurst() async {
        let debouncer = Debouncer()
        var count = 0
        for _ in 0..<5 { debouncer.schedule(after: .milliseconds(20)) { count += 1 } }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(count, 1)
    }

    func testCancelPreventsPendingAction() async {
        let debouncer = Debouncer()
        var count = 0
        debouncer.schedule(after: .milliseconds(20)) { count += 1 }
        debouncer.cancel()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(count, 0)
    }

    func testSeparatedCallsEachFire() async {
        let debouncer = Debouncer()
        var count = 0
        debouncer.schedule(after: .milliseconds(15)) { count += 1 }
        try? await Task.sleep(for: .milliseconds(50))
        debouncer.schedule(after: .milliseconds(15)) { count += 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(count, 2)
    }
}

/// Unit tests for the streaming reveal rate.
final class StreamingPacerTests: XCTestCase {
    private let tick: TimeInterval = 1.0 / 60
    private let horizon: TimeInterval = 0.25
    private var frames: Int { StreamingPacer.frames(horizon: horizon, tick: tick) }

    func testEmptyBacklogRevealsNothing() {
        XCTAssertEqual(StreamingPacer.sliceLength(backlog: 0, framesLeft: frames), 0)
    }

    func testTrickleStillMovesEveryFrame() {
        // One-character deltas must not stall waiting for a bigger backlog.
        XCTAssertEqual(StreamingPacer.sliceLength(backlog: 1, framesLeft: frames), 1)
        XCTAssertEqual(StreamingPacer.sliceLength(backlog: 3, framesLeft: frames), 1)
    }

    func testBiggerBacklogRevealsFaster() {
        let small = StreamingPacer.sliceLength(backlog: 60, framesLeft: frames)
        let large = StreamingPacer.sliceLength(backlog: 600, framesLeft: frames)
        XCTAssertGreaterThan(large, small)
    }

    func testSliceNeverOutrunsTheBacklog() {
        for backlog in [1, 7, 60, 601, 5000] {
            XCTAssertLessThanOrEqual(
                StreamingPacer.sliceLength(backlog: backlog, framesLeft: frames), backlog
            )
        }
    }

    /// The deadline has to be real. Spreading the backlog over the *remaining*
    /// frames drains it on time; dividing by the full horizon every frame decays
    /// exponentially and leaves the last characters trickling out well past it.
    func testBacklogDrainsWithinTheHorizon() {
        for backlog in [5, 120, 2000, 20000] {
            var remaining = backlog
            var left = frames
            var used = 0
            while remaining > 0 {
                remaining -= StreamingPacer.sliceLength(backlog: remaining, framesLeft: left)
                left = max(1, left - 1)
                used += 1
                XCTAssertLessThanOrEqual(used, frames, "backlog \(backlog) outlived the horizon")
            }
        }
    }

    /// A stream that keeps arriving must not push the reveal into a backlog it
    /// never works off: with a chunk landing every frame, what's shown has to
    /// stay within a horizon's worth of what's been received.
    func testSteadyStreamKeepsUpWithTheEngine() {
        var remaining = 0
        var left = frames
        for _ in 0..<600 {
            remaining += 8 // an eight-character delta every frame
            left = frames // arriving text resets the deadline
            remaining -= StreamingPacer.sliceLength(backlog: remaining, framesLeft: left)
            left = max(1, left - 1)
        }
        XCTAssertLessThanOrEqual(remaining, 8 * frames)
    }

    func testTighterFinishingDeadlineRevealsFaster() {
        let paced = StreamingPacer.sliceLength(backlog: 600, framesLeft: frames)
        let finishing = StreamingPacer.sliceLength(
            backlog: 600, framesLeft: StreamingPacer.frames(horizon: 0.08, tick: tick)
        )
        XCTAssertGreaterThan(finishing, paced)
    }
}

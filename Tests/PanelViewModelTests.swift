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

    func testTogglePageModeDismissesMetricsOverlayAndSwitches() {
        let vm = PanelViewModel()
        vm.metricsRunID = "engine-1"

        vm.togglePageMode()

        // The metrics overlay is a plain in-window view, so switching modes just
        // clears it and flips the mode in one synchronous step.
        XCTAssertNil(vm.metricsRunID, "switching modes closes the metrics overlay")
        XCTAssertTrue(vm.pageMode)
    }

    func testMetricsPopoverBindingIsScopedToOneEngine() {
        let vm = PanelViewModel()
        let first = vm.metricsPopoverBinding(for: "e1")
        XCTAssertFalse(first.wrappedValue)

        first.wrappedValue = true
        XCTAssertEqual(vm.metricsRunID, "e1")
        // Only the owning engine's binding reads true — opening one closes any
        // other (a single popover at a time).
        XCTAssertTrue(vm.metricsPopoverBinding(for: "e1").wrappedValue)
        XCTAssertFalse(vm.metricsPopoverBinding(for: "e2").wrappedValue)

        first.wrappedValue = false
        XCTAssertNil(vm.metricsRunID)
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

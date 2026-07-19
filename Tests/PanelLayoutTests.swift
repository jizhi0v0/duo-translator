import XCTest
@testable import DuoTranslator

/// Guards the panel's sizing rules against different input lengths: empty → one
/// line → many lines → overflow. Each feature (adaptive input height, window
/// fit, per-card body cap, whole-line body snapping) is exercised across that
/// whole range so a regression that breaks the UI at some length is caught.
final class PanelLayoutTests: XCTestCase {

    // MARK: - Page-mode output height

    func testUnmeasuredPageOutputUsesLoadingFloorInsteadOfFullBudget() {
        XCTAssertEqual(
            PageModeLayout.outputHeight(measured: nil, floor: 80, cap: 500),
            80
        )
    }

    func testMeasuredPageOutputGrowsAndCaps() {
        XCTAssertEqual(PageModeLayout.outputHeight(measured: 140, floor: 80, cap: 500), 140)
        XCTAssertEqual(PageModeLayout.outputHeight(measured: 900, floor: 80, cap: 500), 500)
    }

    // MARK: - Mode-switch measurement gating

    func testModeSwitchRejectsOutgoingModeMeasurement() {
        XCTAssertFalse(PanelLayout.canUseResultMeasurement(
            measuredForPageMode: false,
            currentPageMode: true,
            awaitingNewMeasurement: true
        ))
    }

    func testModeSwitchAcceptsFreshMeasurementFromVisibleMode() {
        XCTAssertTrue(PanelLayout.canUseResultMeasurement(
            measuredForPageMode: true,
            currentPageMode: true,
            awaitingNewMeasurement: false
        ))
    }

    // MARK: - Window fit (grows with content, clamped to floor/ceiling)

    func testWindowHeightClampsToFloorForEmptyContent() {
        // No results yet: tiny content shouldn't collapse below the floor.
        let h = PanelLayout.windowHeight(chrome: 60, result: 0, buffer: 6, floor: 220, ceiling: 760)
        XCTAssertEqual(h, 220)
    }

    func testWindowHeightTracksContentInTheMiddle() {
        let h = PanelLayout.windowHeight(chrome: 224, result: 245, buffer: 6, floor: 220, ceiling: 760)
        XCTAssertEqual(h, 475) // 224 + 245 + 6, within [220, 760]
    }

    func testWindowHeightClampsToCeilingForLongContent() {
        let h = PanelLayout.windowHeight(chrome: 224, result: 5000, buffer: 6, floor: 220, ceiling: 760)
        XCTAssertEqual(h, 760)
    }

    func testWindowHeightIsMonotonicAndBoundedAcrossLengths() {
        let floor: CGFloat = 220, ceiling: CGFloat = 760
        var previous: CGFloat = 0
        for result in stride(from: CGFloat(0), through: 6000, by: 37) {
            let h = PanelLayout.windowHeight(chrome: 224, result: result, buffer: 6, floor: floor, ceiling: ceiling)
            XCTAssertGreaterThanOrEqual(h, floor)
            XCTAssertLessThanOrEqual(h, ceiling)
            XCTAssertGreaterThanOrEqual(h, previous, "window height must not shrink as content grows")
            previous = h
        }
    }

    // MARK: - Input editor (adaptive height following typed content)

    func testEditorHeightStartsAtMinForShortInput() {
        // Empty / one short line sits at the minimum, not collapsed.
        XCTAssertEqual(PanelLayout.editorHeight(content: 0, min: 60, max: 200), 60)
        XCTAssertEqual(PanelLayout.editorHeight(content: 41, min: 60, max: 200), 60)
    }

    func testEditorHeightFollowsContentBetweenBounds() {
        XCTAssertEqual(PanelLayout.editorHeight(content: 120, min: 60, max: 200), 120)
    }

    func testEditorHeightCapsForLongInput() {
        // Very long input stops growing (then scrolls internally).
        XCTAssertEqual(PanelLayout.editorHeight(content: 5000, min: 60, max: 200), 200)
    }

    func testEditorHeightIsMonotonicAndBounded() {
        var previous: CGFloat = 0
        for content in stride(from: CGFloat(0), through: 1000, by: 13) {
            let h = PanelLayout.editorHeight(content: content, min: 60, max: 200)
            XCTAssertGreaterThanOrEqual(h, 60)
            XCTAssertLessThanOrEqual(h, 200)
            XCTAssertGreaterThanOrEqual(h, previous)
            previous = h
        }
    }

    // MARK: - Per-card body cap (shrinks as cards are added, never below floor)

    func testPerCardBodyMaxShrinksWithMoreCards() {
        let one = PanelLayout.perCardBodyMax(count: 1, budget: 536, cardChrome: 82, floor: 150)
        let two = PanelLayout.perCardBodyMax(count: 2, budget: 536, cardChrome: 82, floor: 150)
        XCTAssertGreaterThan(one, two)
        XCTAssertEqual(two, (536 - 2 * 82) / 2, accuracy: 0.5) // 186
    }

    func testPerCardBodyMaxHonorsFloorWithManyCards() {
        // Many providers: each body is floored rather than going to zero.
        let many = PanelLayout.perCardBodyMax(count: 8, budget: 536, cardChrome: 82, floor: 150)
        XCTAssertEqual(many, 150)
    }

    func testPerCardBodyMaxFillsBudgetAboveFloor() {
        // Above the floor, count * (body + chrome) uses the whole budget.
        for count in 1...3 {
            let body = PanelLayout.perCardBodyMax(count: count, budget: 536, cardChrome: 82, floor: 150)
            guard body > 150 else { continue }
            let total = CGFloat(count) * (body + 82)
            XCTAssertEqual(total, 536, accuracy: 0.5)
        }
    }

    func testPerCardBodyMaxHandlesZeroCount() {
        // Defensive: count 0 must not divide-by-zero or go negative.
        let h = PanelLayout.perCardBodyMax(count: 0, budget: 536, cardChrome: 82, floor: 150)
        XCTAssertGreaterThanOrEqual(h, 150)
    }

    func testCeilingDerivedBudgetKeepsPanelWithinCeiling() {
        // Regression: a fixed budget let a tall chrome (adaptive input grown to
        // several lines) push the result cards past the window ceiling, clipping
        // the bottom card off-screen with no reachable scrollbar. With the budget
        // derived from `ceiling - chrome`, chrome + cards always fits the ceiling.
        let ceiling: CGFloat = 760, buffer: CGFloat = 6, listPad: CGFloat = 20, cardChrome: CGFloat = 82
        for chrome in stride(from: CGFloat(120), through: 480, by: 7) {
            for count in 1...3 {
                let budget = max(200, ceiling - chrome - buffer)
                let body = PanelLayout.perCardBodyMax(
                    count: count, budget: budget - listPad, cardChrome: cardChrome, floor: 96)
                // The readable floor can exceed a very tight budget by design;
                // assert the fit only in the normal (non-floored) regime.
                guard body > 96 else { continue }
                let resultList = CGFloat(count) * (body + cardChrome) + listPad
                XCTAssertLessThanOrEqual(chrome + resultList + buffer, ceiling + 0.5,
                                         "chrome=\(chrome) count=\(count) overflowed the ceiling")
            }
        }
    }

    // MARK: - Whole-line body snapping (a capped body never cuts a line in half)

    func testLineAlignedHeightNeverExceedsCeiling() {
        for ceiling in stride(from: CGFloat(40), through: 800, by: 1) {
            XCTAssertLessThanOrEqual(PanelLayout.lineAlignedBodyHeight(atMost: ceiling), ceiling)
        }
    }

    func testLineAlignedHeightFitsWholeLines() {
        // Every result must be insets + k whole lines (k ≥ 1), i.e. no partial
        // line — the regression the user hit ("stuck at a weird height").
        let lh = PanelLayout.bodyLineHeight
        let sp = PanelLayout.bodyLineSpacing
        let inset = PanelLayout.bodyVInset * 2
        for ceiling in stride(from: CGFloat(60), through: 800, by: 1) {
            let h = PanelLayout.lineAlignedBodyHeight(atMost: ceiling)
            let lines = (h - inset + sp) / (lh + sp)
            let rounded = lines.rounded()
            XCTAssertEqual(lines, rounded, accuracy: 0.01,
                           "height \(h) for ceiling \(ceiling) is not a whole number of lines")
            XCTAssertGreaterThanOrEqual(rounded, 1)
        }
    }

    func testLineAlignedHeightIsMonotonic() {
        var previous: CGFloat = 0
        for ceiling in stride(from: CGFloat(60), through: 800, by: 1) {
            let h = PanelLayout.lineAlignedBodyHeight(atMost: ceiling)
            XCTAssertGreaterThanOrEqual(h, previous)
            previous = h
        }
    }

    // MARK: - Stable result body (streaming never changes card/window height)

    func testStableBodyHeightUsesPreferredViewportWhenItFits() {
        let h = PanelLayout.stableBodyHeight(preferred: 96, cap: 300)
        XCTAssertEqual(h, PanelLayout.lineAlignedBodyHeight(atMost: 96))
        XCTAssertLessThanOrEqual(h, 96)
    }

    func testStableBodyHeightHonorsTighterPerCardCap() {
        let h = PanelLayout.stableBodyHeight(preferred: 96, cap: 72)
        XCTAssertEqual(h, PanelLayout.lineAlignedBodyHeight(atMost: 72))
        XCTAssertLessThanOrEqual(h, 72)
    }
}

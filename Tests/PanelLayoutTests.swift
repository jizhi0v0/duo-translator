import XCTest
@testable import DuoTranslator

/// Guards the panel's sizing rules against different input lengths: empty → one
/// line → many lines → overflow. Each feature (adaptive input height, window
/// fit, per-card body cap, whole-line body snapping) is exercised across that
/// whole range so a regression that breaks the UI at some length is caught.
final class PanelLayoutTests: XCTestCase {

    // MARK: - Metrics tips placement

    func testMetricsTipsUsesBelowWhenThereIsRoom() {
        let placement = MetricsOverlayPlacement.fit(
            gauge: CGRect(x: 100, y: 50, width: 16, height: 16),
            naturalSize: CGSize(width: 240, height: 220),
            containerSize: CGSize(width: 480, height: 600)
        )
        XCTAssertEqual(placement.origin.y, 72)
        XCTAssertEqual(placement.size.height, 220, "full room: renders at its natural height")
    }

    func testMetricsTipsFlipsAboveNearPanelBottom() {
        let gauge = CGRect(x: 100, y: 500, width: 16, height: 16)
        let placement = MetricsOverlayPlacement.fit(
            gauge: gauge,
            naturalSize: CGSize(width: 240, height: 220),
            containerSize: CGSize(width: 480, height: 600)
        )
        XCTAssertEqual(placement.origin.y, gauge.minY - 6 - 220)
        XCTAssertGreaterThanOrEqual(placement.origin.y, 8)
        XCTAssertEqual(placement.size.height, 220, "full room on the flipped side too")
    }

    func testMetricsTipsClampsHorizontallyInsidePanel() {
        let placement = MetricsOverlayPlacement.fit(
            gauge: CGRect(x: 470, y: 50, width: 10, height: 10),
            naturalSize: CGSize(width: 240, height: 220),
            containerSize: CGSize(width: 480, height: 600)
        )
        XCTAssertEqual(placement.origin.x, 232)
    }

    /// On a short panel where the card fits neither above nor below the gauge
    /// at full height, flipping above unclamped (the old rule) would land it
    /// on top of the toolbar's own buttons — `topInset` marks that region
    /// off-limits, so the card shrinks (its own scroll view gives up rows)
    /// to whatever room the chosen side actually has instead.
    func testMetricsTipsNeverCoversProtectedChrome() {
        let gauge = CGRect(x: 100, y: 240, width: 16, height: 16)
        let naturalSize = CGSize(width: 240, height: 220)
        let containerSize = CGSize(width: 480, height: 300)
        let topInset: CGFloat = 60

        // Without the inset, this exact geometry flips above the gauge at
        // its full natural height.
        let unprotected = MetricsOverlayPlacement.fit(
            gauge: gauge, naturalSize: naturalSize, containerSize: containerSize
        )
        XCTAssertEqual(unprotected.origin.y, gauge.minY - 6 - naturalSize.height)
        XCTAssertEqual(unprotected.size.height, naturalSize.height)

        let protected = MetricsOverlayPlacement.fit(
            gauge: gauge, naturalSize: naturalSize, containerSize: containerSize, topInset: topInset
        )
        XCTAssertGreaterThanOrEqual(protected.origin.y, 8 + topInset)
        XCTAssertLessThan(protected.size.height, naturalSize.height, "shrinks rather than spilling into the chrome")
        XCTAssertLessThanOrEqual(
            protected.origin.y + protected.size.height, containerSize.height - 8,
            "shrinks rather than spilling past the window edge too"
        )
    }

    // MARK: - Result-list scroll viewport

    func testResultListGrowsToContentBelowBudget() {
        XCTAssertEqual(PanelLayout.scrollViewportHeight(content: 180, budget: 300), 180)
    }

    func testResultListCapsAtBudgetWhenCardsOverflow() {
        XCTAssertEqual(PanelLayout.scrollViewportHeight(content: 400, budget: 271), 271)
    }

    func testResultListViewportNeverBecomesNegative() {
        XCTAssertEqual(PanelLayout.scrollViewportHeight(content: 400, budget: -20), 0)
    }

    // MARK: - Window drag event order

    func testWindowDragIsActiveWhileMouseDownIsNewest() {
        XCTAssertTrue(WindowDragState.isActive(downEventAge: 0.01, upEventAge: 3))
    }

    func testWindowDragEndsWhenMouseUpBecomesNewest() {
        XCTAssertFalse(WindowDragState.isActive(downEventAge: 3, upEventAge: 0.01))
    }

    func testWindowDragAppliesExactPointerDeltaWithoutScreenClamp() {
        let origin = WindowDragState.windowOrigin(
            startOrigin: NSPoint(x: 720, y: 493),
            startPointer: NSPoint(x: 900, y: 900),
            currentPointer: NSPoint(x: 546, y: -100)
        )
        XCTAssertEqual(origin.x, 366)
        XCTAssertEqual(origin.y, -507)
    }

    func testWindowDragStopsBeforeDockAndMenuBar() {
        let visible = NSRect(x: 0, y: 62, width: 1920, height: 988)
        let size = NSSize(width: 480, height: 709)

        let belowDock = WindowDragState.constrainedOrigin(
            proposed: NSPoint(x: 300, y: -500),
            windowSize: size,
            visibleFrame: visible,
            padding: 24
        )
        XCTAssertEqual(belowDock.y, 86)

        let aboveMenuBar = WindowDragState.constrainedOrigin(
            proposed: NSPoint(x: 300, y: 900),
            windowSize: size,
            visibleFrame: visible,
            padding: 24
        )
        XCTAssertEqual(aboveMenuBar.y, 317)
    }

    func testWindowDragCanSitFlushAgainstUsableScreenEdge() {
        let visible = NSRect(x: 0, y: 62, width: 1920, height: 988)
        let origin = WindowDragState.constrainedOrigin(
            proposed: NSPoint(x: -100, y: -500),
            windowSize: NSSize(width: 480, height: 709),
            visibleFrame: visible,
            padding: 0
        )
        XCTAssertEqual(origin.x, visible.minX)
        XCTAssertEqual(origin.y, visible.minY)
    }

    // MARK: - Fit allowance at rest (user-positioned panel)

    func testAllowedFitUsesFullCeilingFromDefaultTopPosition() {
        // Default opening puts the top at the padded screen top, so the room
        // below it covers the whole usable ceiling.
        XCTAssertEqual(
            PanelLayout.allowedFitHeight(
                roomBelowTop: 1031, screenCeiling: 1007, minHeight: 220, chrome: 246
            ),
            1007
        )
    }

    func testAllowedFitPreservesDraggedTopEdge() {
        // Panel dragged to mid-screen: growth may fill only the room below the
        // chosen top edge, so a long result can never shove the panel back up.
        XCTAssertEqual(
            PanelLayout.allowedFitHeight(
                roomBelowTop: 475, screenCeiling: 1007, minHeight: 220, chrome: 246
            ),
            475
        )
    }

    func testDraggedLowPanelFitsWithinRoomBelowTopInsteadOfJumping() {
        // The release-time catch-up fit for a mid-screen panel with a long
        // streamed result: height stops at the room below the top edge.
        let allowed = PanelLayout.allowedFitHeight(
            roomBelowTop: 475, screenCeiling: 1007, minHeight: 220, chrome: 246
        )
        let desired = PanelLayout.windowHeight(
            chrome: 240, result: 761, buffer: 6, floor: 220, ceiling: allowed
        )
        XCTAssertEqual(desired, 475)
    }

    func testAllowedFitLiftsOnlyByTheMinimumHeightShortfall() {
        XCTAssertEqual(
            PanelLayout.allowedFitHeight(
                roomBelowTop: 100, screenCeiling: 1007, minHeight: 220, chrome: 150
            ),
            220
        )
    }

    func testAllowedFitNeverClipsTheChrome() {
        // Parked at the bottom while the input grew taller than the remaining
        // room: the panel may lift just far enough to keep the chrome visible.
        XCTAssertEqual(
            PanelLayout.allowedFitHeight(
                roomBelowTop: 250, screenCeiling: 1007, minHeight: 220, chrome: 326
            ),
            326
        )
    }

    func testAllowedFitKeepsAMinimumResultStripWhenParkedAtTheBottom() {
        // With cards on screen the result area may never squeeze to zero: the
        // panel lifts by exactly the chrome+strip shortfall.
        XCTAssertEqual(
            PanelLayout.allowedFitHeight(
                roomBelowTop: 285, screenCeiling: 1007, minHeight: 220,
                chrome: 246, resultFloor: 150
            ),
            396
        )
    }

    func testAllowedFitWithoutResultsReservesNoStrip() {
        XCTAssertEqual(
            PanelLayout.allowedFitHeight(
                roomBelowTop: 285, screenCeiling: 1007, minHeight: 220, chrome: 246
            ),
            285
        )
    }

    // MARK: - Cross-screen drag

    func testDragStaysFullyInsideASingleScreen() {
        let visible = NSRect(x: 0, y: 62, width: 1920, height: 988)
        let origin = WindowDragState.dragOrigin(
            proposed: NSPoint(x: -100, y: -500),
            windowSize: NSSize(width: 480, height: 709),
            toolbarBandHeight: 36,
            pointerScreen: visible,
            screens: [visible]
        )
        XCTAssertEqual(origin.x, visible.minX)
        XCTAssertEqual(origin.y, visible.minY)
    }

    func testDragStraddlesEqualSideBySideScreensWithoutJumping() {
        let a = NSRect(x: 0, y: 62, width: 1920, height: 988)
        let b = NSRect(x: 1920, y: 62, width: 1920, height: 988)
        // Window half on each screen: the proposed origin is kept as-is
        // instead of teleporting into the pointer's screen.
        let origin = WindowDragState.dragOrigin(
            proposed: NSPoint(x: 1700, y: 300),
            windowSize: NSSize(width: 480, height: 500),
            toolbarBandHeight: 36,
            pointerScreen: b,
            screens: [a, b]
        )
        XCTAssertEqual(origin.x, 1700)
        XCTAssertEqual(origin.y, 300)
    }

    func testDragStopsAtTheOuterEdgeOfTheArrangement() {
        let a = NSRect(x: 0, y: 62, width: 1920, height: 988)
        let b = NSRect(x: 1920, y: 62, width: 1920, height: 988)
        let origin = WindowDragState.dragOrigin(
            proposed: NSPoint(x: 3600, y: 300),
            windowSize: NSSize(width: 480, height: 500),
            toolbarBandHeight: 36,
            pointerScreen: b,
            screens: [a, b]
        )
        XCTAssertEqual(origin.x, 3840 - 480)
    }

    func testDragKeepsWindowOffScreensThatCannotShowItsToolbar() {
        // A short laptop screen beside a tall external: at a height that only
        // exists on the external, the window cannot straddle into the laptop.
        let tall = NSRect(x: 0, y: 0, width: 1920, height: 1050)
        let laptop = NSRect(x: 1920, y: 0, width: 1512, height: 800)
        let origin = WindowDragState.dragOrigin(
            proposed: NSPoint(x: 1800, y: 500),
            windowSize: NSSize(width: 480, height: 500),
            toolbarBandHeight: 36,
            pointerScreen: tall,
            screens: [tall, laptop]
        )
        XCTAssertEqual(origin.x, 1920 - 480)
        XCTAssertEqual(origin.y, 500)
    }

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

    // MARK: - Growing result body (grows with content, stops at the card's cap)

    func testGrowingBodyStartsAtFloorBeforeMeasurement() {
        let h = PanelLayout.growingBodyHeight(measured: nil, floor: 96, cap: 300)
        XCTAssertEqual(h, PanelLayout.stableBodyHeight(preferred: 96, cap: 300))
    }

    func testGrowingBodyKeepsFloorForShortContent() {
        let floor = PanelLayout.stableBodyHeight(preferred: 96, cap: 300)
        let h = PanelLayout.growingBodyHeight(measured: 30, floor: 96, cap: 300)
        XCTAssertEqual(h, floor)
    }

    func testGrowingBodyFollowsContentBetweenFloorAndCap() {
        let h = PanelLayout.growingBodyHeight(measured: 210, floor: 96, cap: 300)
        XCTAssertEqual(h, 210)
    }

    func testGrowingBodyStopsAtCapOnWholeLines() {
        let h = PanelLayout.growingBodyHeight(measured: 900, floor: 96, cap: 300)
        XCTAssertEqual(h, PanelLayout.lineAlignedBodyHeight(atMost: 300))
        XCTAssertLessThanOrEqual(h, 300)
    }

    func testGrowingBodyIsMonotonicInContentHeight() {
        var previous = PanelLayout.growingBodyHeight(measured: nil, floor: 96, cap: 300)
        for measured in stride(from: CGFloat(0), through: 600, by: 7) {
            let h = PanelLayout.growingBodyHeight(measured: measured, floor: 96, cap: 300)
            XCTAssertGreaterThanOrEqual(h, previous)
            XCTAssertLessThanOrEqual(h, 300)
            previous = h
        }
    }

    // MARK: - Dragged body height

    /// The dragged value is a ceiling, not a fixed height: a later short
    /// translation must not sit in a tall box of empty space (which is what
    /// made the old behaviour need a manual reset every time).
    func testDraggedHeightActsAsACeiling() {
        let h = PanelLayout.bodyHeight(dragged: 220, measured: 40, floor: 96, cap: 300)
        XCTAssertEqual(h, PanelLayout.growingBodyHeight(measured: 40, floor: 96, cap: 220))
        XCTAssertLessThan(h, 220)
    }

    func testDraggedCeilingStopsLongContent() {
        let h = PanelLayout.bodyHeight(dragged: 120, measured: 900, floor: 96, cap: 300)
        XCTAssertEqual(h, PanelLayout.lineAlignedBodyHeight(atMost: 120))
    }

    /// The window's own share still wins: a ceiling dragged (or restored from
    /// defaults) larger than the card's slice can't push the card off-screen.
    func testWindowShareWinsOverATallerDraggedCeiling() {
        let h = PanelLayout.bodyHeight(dragged: 5000, measured: 900, floor: 96, cap: 300)
        XCTAssertEqual(h, PanelLayout.lineAlignedBodyHeight(atMost: 300))
    }

    func testNoDragFallsBackToFollowingTheContent() {
        let h = PanelLayout.bodyHeight(dragged: nil, measured: 210, floor: 96, cap: 300)
        XCTAssertEqual(h, PanelLayout.growingBodyHeight(measured: 210, floor: 96, cap: 300))
    }

    func testDragIsClampedToTheCardsShareOfTheWindow() {
        let tall = PanelLayout.clampDraggedBodyHeight(5000, floor: 96, cap: 300)
        XCTAssertEqual(tall, PanelLayout.lineAlignedBodyHeight(atMost: 300))
        let short = PanelLayout.clampDraggedBodyHeight(0, floor: 96, cap: 300)
        XCTAssertEqual(short, PanelLayout.stableBodyHeight(preferred: 96, cap: 300))
    }

    /// Several providers in a short window: the cap can be tighter than the
    /// floor, and a drag must not sneak past it in either direction.
    func testDragStaysWithinATightCap() {
        for height in [CGFloat(0), 50, 96, 400] {
            let h = PanelLayout.clampDraggedBodyHeight(height, floor: 96, cap: 72)
            XCTAssertLessThanOrEqual(h, 72)
            XCTAssertGreaterThan(h, 0)
        }
    }

    /// A cap tighter than the floor (many providers sharing a short window) must
    /// still win — the card never grows past its share of the result area.
    func testGrowingBodyNeverExceedsATightCap() {
        for measured in [CGFloat(0), 50, 96, 400] {
            let h = PanelLayout.growingBodyHeight(measured: measured, floor: 96, cap: 72)
            XCTAssertLessThanOrEqual(h, 72)
        }
    }
}

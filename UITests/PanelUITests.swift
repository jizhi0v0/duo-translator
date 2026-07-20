import AppKit
import XCTest

/// End-to-end UI tests for the translator panel. The app is launched with the
/// `-uiTest` argument, which shows the panel seeded from `UITEST_INPUT` — so the
/// tests drive real rendering (adaptive sizing, copy-button feedback, icon
/// stability) deterministically, without simulating hotkeys or keyboard focus.
///
/// The panel is an accessory-app `NSPanel`: the accessibility tree exposes it as
/// a top-level `Group` (not a `Window`), so size assertions read `groups.first`.
final class PanelUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        // Terminate between tests: the app is a background accessory, and a
        // lingering instance's panel would overlap the next one and swallow
        // coordinate clicks (an ordering-dependent flake).
        app?.terminate()
        app = nil
    }

    @discardableResult
    private func launch(seed: String) -> XCUIApplication {
        app?.terminate() // clean any prior instance before spawning a new one
        let a = XCUIApplication()
        a.launchArguments += ["-uiTest"]
        a.launchEnvironment["UITEST_INPUT"] = seed
        a.launch()
        app = a
        XCTAssertTrue(a.buttons["input.copy"].waitForExistence(timeout: 10),
                      "panel did not appear")
        return a
    }

    /// The panel's own ceiling: the screen's visible height less the margin it
    /// keeps top and bottom (`PanelController.screenPadding`, 24 each side).
    private static var panelHeightCeiling: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 1000) - 48 + 1
    }

    /// The panel container (top-level Group). Its frame is the panel's size.
    private func panel(_ app: XCUIApplication) -> XCUIElement {
        app.groups.firstMatch
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollEvery: useconds_t = 30_000,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(pollEvery)
        }
        return condition()
    }

    /// Clicks the copy button until it reports the "copied" confirmation. The
    /// panel is a non-activating accessory window, which can drop the first
    /// synthesized click just after appearing; retrying makes it deterministic.
    private func clickCopyUntilConfirmed(
        _ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0..<8 {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            // The value flips to "copied" on a successful click (and only
            // reverts ~1.2s later), so a short poll distinguishes hit from miss.
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline {
                if button.value as? String == "copied" { return }
                usleep(60_000)
            }
        }
        XCTFail("copy button never confirmed 'copied' after retries", file: file, line: line)
    }

    @discardableResult
    private func launch(
        seed: String,
        results: Int,
        streaming: Bool = false,
        resultText: String? = nil
    ) -> XCUIApplication {
        app?.terminate()
        let a = XCUIApplication()
        a.launchArguments += ["-uiTest"]
        a.launchEnvironment["UITEST_INPUT"] = seed
        a.launchEnvironment["UITEST_RESULTS"] = String(results)
        if streaming { a.launchEnvironment["UITEST_STREAMING"] = "1" }
        if let resultText { a.launchEnvironment["UITEST_RESULT_TEXT"] = resultText }
        a.launch()
        app = a
        XCTAssertTrue(a.buttons.matching(identifier: "result.copy").firstMatch.waitForExistence(timeout: 10),
                      "result cards did not appear")
        return a
    }

    // MARK: - Panel presentation

    func testPanelAppearsWithInputControls() {
        let app = launch(seed: "hello world")
        XCTAssertTrue(app.buttons["input.copy"].exists,
                      "the panel and its input footer copy button should appear")
        XCTAssertTrue(app.buttons["input.speak"].exists)
    }

    // MARK: - Width

    func testPanelWidthIsAboutFourEighty() {
        let app = launch(seed: "hi")
        XCTAssertEqual(panel(app).frame.width, 480, accuracy: 8,
                       "panel width should be ~480pt (was \(panel(app).frame.width))")
    }

    func testPageModeSwitchesWidthAndReturnsToCompactLayout() {
        let app = launch(seed: "short source", results: 1)
        let pageMode = app.buttons["toolbar.pageMode"]
        XCTAssertTrue(pageMode.waitForExistence(timeout: 10))

        pageMode.click()
        XCTAssertTrue(waitUntil(timeout: 3) { self.panel(app).frame.width > 600 },
                      "page mode never installed its wide layout")
        XCTAssertTrue(waitUntil(timeout: 3) { self.panel(app).frame.height > 700 },
                      "the long completed result never fitted to page height")
        let firstPageHeight = panel(app).frame.height
        XCTAssertGreaterThan(panel(app).frame.height, 0)
        XCTAssertLessThanOrEqual(panel(app).frame.height, Self.panelHeightCeiling)

        pageMode.click()
        XCTAssertTrue(waitUntil(timeout: 3) { abs(self.panel(app).frame.width - 480) < 8 },
                      "compact mode never restored its layout")
        XCTAssertGreaterThan(panel(app).frame.height, 0)

        // Re-entering with unchanged text still needs a fresh measurement. The
        // TextKit reader used to suppress it as a duplicate, leaving the panel
        // stuck at the compact mode's height with an old backing-store snapshot.
        pageMode.click()
        XCTAssertTrue(waitUntil(timeout: 3) { self.panel(app).frame.width > 600 },
                      "page mode did not reopen on the second switch")
        XCTAssertTrue(waitUntil(timeout: 3) {
            abs(self.panel(app).frame.height - firstPageHeight) < 5
        }, "second page-mode entry never restored its measured height")
    }

    func testImmediatePageModeSwitchWhileStreamingStaysCompact() {
        let app = launch(seed: "source waiting for its first chunk", results: 1, streaming: true)
        let pageMode = app.buttons["toolbar.pageMode"]
        XCTAssertTrue(pageMode.waitForExistence(timeout: 10))

        pageMode.click()
        XCTAssertTrue(waitUntil(timeout: 3) { self.panel(app).frame.width > 600 },
                      "page mode never installed its wide layout")
        XCTAssertLessThan(panel(app).frame.height, 600,
                          "an unmeasured loading page must not stretch to the ceiling")
    }

    func testPageReaderKeepsEveryParagraphAfterCompletedSwitch() {
        let tail = "UITEST_COMPLETED_TRANSLATION_TAIL"
        let translation = "first paragraph\n\nsecond paragraph\nthird paragraph\n\(tail)"
        let app = launch(
            seed: "single source paragraph",
            results: 1,
            resultText: translation
        )
        app.buttons["toolbar.pageMode"].click()

        let reader = app.textViews["page.reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) {
            (reader.value as? String)?.contains(tail) == true
        }, "completed page mode dropped translation paragraphs after the first source paragraph")
    }

    func testPageReaderReceivesStreamTailAfterMidStreamSwitch() {
        let tail = "UITEST_STREAMING_TRANSLATION_TAIL"
        let translation = String(repeating: "streaming paragraph content. ", count: 18) + tail
        let app = launch(
            seed: "source waiting while page mode opens",
            results: 1,
            streaming: true,
            resultText: translation
        )
        app.buttons["toolbar.pageMode"].click()

        let reader = app.textViews["page.reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 8) {
            (reader.value as? String)?.contains(tail) == true
        }, "page reader stopped receiving chunks after the mode switch")
    }

    // MARK: - Adaptive input height (grows with content across lengths)

    func testPanelGrowsWithLongerInput() {
        let short = launch(seed: "one short line")
        let shortHeight = panel(short).frame.height

        let longText = (1...14)
            .map { "line \($0) of a considerably longer multi-line input block" }
            .joined(separator: "\n")
        let long = launch(seed: longText) // terminates the short instance first
        let longHeight = panel(long).frame.height

        XCTAssertGreaterThan(longHeight, shortHeight + 40,
                             "a much taller input must grow the panel (short=\(shortHeight), long=\(longHeight))")
    }

    // MARK: - Copy button feedback + no jitter

    func testCopyButtonShowsConfirmationThenReverts() {
        let app = launch(seed: "copy this text")
        let copy = app.buttons["input.copy"]
        XCTAssertEqual(copy.value as? String, "idle", "starts in the idle state")

        // Confirmation feedback appears (icon → green checkmark, value → copied).
        clickCopyUntilConfirmed(copy)

        // And auto-reverts to idle after the ~1.2s confirmation window.
        expectation(for: NSPredicate(format: "value == %@", "idle"), evaluatedWith: copy)
        waitForExpectations(timeout: 3)
    }

    func testCopyIconSwapDoesNotResizePanelOrShiftNeighbors() {
        // The regression: `checkmark` is taller than `doc.on.doc`, so the icon
        // swap grew the action row and the whole panel refit (jitter). The fixed
        // icon box must keep the panel height constant and leave the neighboring
        // speak button exactly where it was.
        let app = launch(seed: "copy this text")
        let copy = app.buttons["input.copy"]
        let speak = app.buttons["input.speak"]

        let panelBefore = panel(app).frame
        let speakBefore = speak.frame

        clickCopyUntilConfirmed(copy)

        XCTAssertEqual(panel(app).frame.height, panelBefore.height, accuracy: 0.5,
                       "panel height changed when the copy icon swapped (jitter)")
        XCTAssertEqual(speak.frame.minY, speakBefore.minY, accuracy: 0.5,
                       "neighboring speak button moved when the copy icon swapped")
        XCTAssertEqual(speak.frame.height, speakBefore.height, accuracy: 0.5)
    }

    // MARK: - Long results fit on screen and scroll

    func testLongResultsStayWithinPanelAndScroll() {
        // A long, wrapping input pushes the chrome tall AND three long result
        // cards fill the rest — the exact shape of the reported bug, where the
        // fixed-budget cards overflowed the ceiling and the bottom card was
        // clipped off the panel with no reachable scrollbar. The ceiling-derived
        // budget must shrink the cards so every one stays within the panel.
        let wrappingInput = String(repeating: "长输入折行 ", count: 60)
        let app = launch(seed: wrappingInput, results: 3)

        let panelFrame = panel(app).frame
        let copies = app.buttons.matching(identifier: "result.copy")
        XCTAssertEqual(copies.count, 3, "all result cards should render")

        // Each result body is its own scroll view; with long text the body is
        // capped and scrollable. Expect the three result bodies (plus the input).
        XCTAssertGreaterThanOrEqual(app.scrollViews.count, 3,
                                    "result bodies should be scroll views")

        // Every card — including the last — must sit within the panel bounds and
        // be reachable. Under the bug the bottom card's footer fell below the
        // panel (maxY > panel.maxY) and was not hittable.
        for i in 0..<copies.count {
            let footer = copies.element(boundBy: i)
            XCTAssertLessThanOrEqual(footer.frame.maxY, panelFrame.maxY + 1,
                "result card \(i) footer clipped below the panel (footer.maxY=\(footer.frame.maxY), panel.maxY=\(panelFrame.maxY))")
            XCTAssertTrue(footer.isHittable,
                "result card \(i) footer is not reachable (clipped off-screen)")
        }

        // The panel itself stays within the screen (its only ceiling).
        XCTAssertLessThanOrEqual(panelFrame.height, Self.panelHeightCeiling,
                                 "panel exceeded the screen (\(panelFrame.height))")
    }

    /// A card's body follows its streamed text: it starts at the one-line floor
    /// and grows as chunks arrive, instead of staying at the minimum while the
    /// text scrolls inside a keyhole.
    func testStreamingCardGrowsWithItsText() {
        let text = String(
            repeating: "流式正文用于验证卡片高度随内容增长，这句话需要足够长以便折行。", count: 8
        )
        let app = launch(seed: "grow", results: 1, streaming: true, resultText: text)
        let card = app.buttons.matching(identifier: "result.copy").firstMatch
        // The seeded stream starts after 3s; the footer button's origin moves
        // down as the body above it grows.
        let footerYBefore = card.frame.origin.y

        XCTAssertTrue(
            waitUntil(timeout: 15) { card.frame.origin.y > footerYBefore + 20 },
            "card body never grew with the stream (footer y \(footerYBefore) -> \(card.frame.origin.y))"
        )
    }

    /// Scrolling while the text streams must not leave the cards hanging out of
    /// the window. The window fit trails a growing card by a frame or two, which
    /// is fine; what is not fine is that overflow persisting — the regression
    /// this catches froze the layout for the whole gesture, so the cards sat
    /// outside the panel until the user let go.
    ///
    /// The scroll is posted as real CGEvents. `XCUIElement.scroll` never reaches
    /// the app's `NSEvent` monitor, so a test written with it exercised none of
    /// this and passed against a build where it was plainly broken by hand.
    func testCardsStayInsideTheWindowWhileScrollingThroughTheStream() {
        let text = String(
            repeating: "流式正文用于验证滚动期间窗口始终跟得上卡片的增长。", count: 10
        )
        let app = launch(seed: "scroll-grow", results: 2, streaming: true, resultText: text)
        let footers = app.buttons.matching(identifier: "result.copy")
        let firstFooterYBefore = footers.firstMatch.frame.origin.y

        // The seeded stream starts at 3s; scroll without a pause across it.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            postScrollUp(in: panel(app).frame)
            usleep(16_000)
            for i in 0..<footers.count {
                let footer = footers.element(boundBy: i)
                guard footer.frame.maxY > panel(app).frame.maxY + 1 else { continue }
                // Outside the window: the fit is allowed to be a frame behind,
                // so give it a moment to catch up before calling it a failure.
                XCTAssertTrue(
                    waitUntil(timeout: 0.5) {
                        footer.frame.maxY <= self.panel(app).frame.maxY + 1
                    },
                    "card \(i) stayed outside the window while scrolling"
                )
            }
        }

        XCTAssertTrue(
            waitUntil(timeout: 6) { footers.firstMatch.frame.origin.y > firstFooterYBefore + 20 },
            "cards never grew with the stream (footer y \(firstFooterYBefore) -> \(footers.firstMatch.frame.origin.y))"
        )
    }

    /// The panel's top edge never moves on its own. Long results extend the
    /// bottom; when that reaches the screen's bottom margin the panel stops
    /// growing (bodies scroll instead) rather than sliding up, which used to
    /// drag the whole window — and the text being read — upward mid-stream.
    func testPanelTopStaysPutWhileResultsGrow() {
        let app = launch(seed: "top pinned")
        let topBefore = panel(app).frame.origin.y
        XCTAssertGreaterThan(panel(app).frame.height, 0)

        // Same panel, now with three long results: as much growth as it can get.
        let grown = launch(seed: "top pinned", results: 3)
        XCTAssertTrue(waitUntil(timeout: 3) { self.panel(grown).frame.height > 400 },
                      "results never grew the panel")
        XCTAssertEqual(panel(grown).frame.origin.y, topBefore, accuracy: 2,
                       "the panel's top edge moved while the content grew")

        // XCUI frames are flipped (origin top-left); NSScreen is not. Convert
        // the visible area's bottom edge before comparing.
        guard let screen = NSScreen.main else { return }
        let flippedVisibleBottom = screen.frame.height - screen.visibleFrame.minY
        XCTAssertLessThanOrEqual(panel(grown).frame.maxY, flippedVisibleBottom - 24 + 1,
                                 "the panel grew past the screen's bottom margin")
    }

    /// The divider above a card's footer sets how tall that card may get: drag
    /// it up and the card (and the window) shrink to match; double-click and it
    /// goes back to following the content.
    func testDraggingTheDividerSetsTheCardsMaximumHeight() {
        // Long result, so the card fills its share and there is height to take
        // away — the drag is a ceiling, so it can only shrink a filled card.
        let app = launch(seed: "resize", results: 1)
        let footer = app.buttons.matching(identifier: "result.copy").firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        let panelHeightBefore = panel(app).frame.height
        let footerYBefore = footer.frame.origin.y

        dragVertically(from: CGPoint(x: footer.frame.midX, y: footerYBefore - 8), by: -120)

        XCTAssertTrue(
            waitUntil(timeout: 3) { footer.frame.origin.y < footerYBefore - 60 },
            "dragging the divider up did not shrink the card (footer y \(footerYBefore) -> \(footer.frame.origin.y))"
        )
        XCTAssertLessThan(
            panel(app).frame.height, panelHeightBefore - 60,
            "the window did not follow the shrunken card"
        )

        // Double-click the divider (now higher, with the footer) to reset. This
        // also clears the preference this test just persisted.
        doubleClick(at: CGPoint(x: footer.frame.midX, y: footer.frame.origin.y - 8))
        XCTAssertTrue(
            waitUntil(timeout: 3) { abs(self.panel(app).frame.height - panelHeightBefore) < 12 },
            "double-click did not restore the automatic height (panel \(panel(app).frame.height), expected ~\(panelHeightBefore))"
        )
    }

    /// Press, move in steps, release — as real HID events, since SwiftUI gestures
    /// never see `XCUIElement`'s synthesized ones.
    private func dragVertically(from start: CGPoint, by dy: CGFloat) {
        post(.leftMouseDown, at: start)
        let steps = 10
        for i in 1...steps {
            post(.leftMouseDragged, at: CGPoint(x: start.x, y: start.y + dy * CGFloat(i) / CGFloat(steps)))
            usleep(20_000)
        }
        post(.leftMouseUp, at: CGPoint(x: start.x, y: start.y + dy))
    }

    private func doubleClick(at point: CGPoint) {
        for _ in 0..<2 {
            post(.leftMouseDown, at: point)
            post(.leftMouseUp, at: point)
            usleep(40_000)
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        if type == .leftMouseDown || type == .leftMouseUp {
            // A double-click needs both presses to carry the click count.
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
        usleep(10_000)
    }

    /// One scroll-up tick over the middle of `frame`, as a real HID event.
    private func postScrollUp(in frame: CGRect) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0
        ) else { return }
        event.location = CGPoint(x: frame.midX, y: frame.midY)
        event.post(tap: .cghidEventTap)
    }
}

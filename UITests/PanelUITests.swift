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

    /// A remembered position (seeded through the app's own settings seam,
    /// because dragging needs event posting the runner may not be allowed to
    /// do) is where the panel opens — not the default top-center placement.
    func testPanelOpensAtRememberedPosition() {
        app?.terminate()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame,
              let primaryHeight = NSScreen.screens.first?.frame.height else {
            XCTFail("no screen available"); return
        }
        let topLeft = CGPoint(
            x: (visible.midX - 340).rounded(),
            y: (visible.maxY - 200).rounded()
        )

        let a = XCUIApplication()
        a.launchArguments += ["-uiTest"]
        a.launchEnvironment["UITEST_INPUT"] = "记住位置"
        a.launchEnvironment["UITEST_PANEL_TOPLEFT"] = "\(Int(topLeft.x)),\(Int(topLeft.y))"
        a.launch()
        app = a
        XCTAssertTrue(a.buttons["input.copy"].waitForExistence(timeout: 10),
                      "panel did not appear")

        let frame = panel(a).frame
        XCTAssertEqual(frame.minX, topLeft.x, accuracy: 2,
                       "panel did not open at the remembered x")
        // XCUI coordinates are top-left based: the Cocoa top edge converts via
        // the primary screen height.
        XCTAssertEqual(frame.minY, primaryHeight - topLeft.y, accuracy: 2,
                       "panel top edge did not open at the remembered position")
    }

    /// Mid-stream, an overflowing body offers the jump-to-latest affordance;
    /// reading stays top-anchored by default, so the button is the opt-in.
    func testFollowStreamButtonAppearsForOverflowingStream() {
        let text = String(
            repeating: "长译文持续增长，超出卡片视口后应出现跳到最新内容的按钮。", count: 80
        )
        let app = launch(seed: "follow", results: 1, streaming: true, resultText: text)
        XCTAssertTrue(
            app.buttons["result.followStream"].waitForExistence(timeout: 10),
            "the follow-stream button never appeared for an overflowing streaming body"
        )
    }

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

        // Each result body is its own scroll view and the provider stack has an
        // outer fallback scroller for the case where card chrome alone is taller
        // than the remaining result area.
        XCTAssertGreaterThanOrEqual(app.scrollViews.count, 3,
                                    "result bodies should be scroll views")
        let list = app.scrollViews["results.listScroll"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "provider list scroll view is missing")
        XCTAssertLessThanOrEqual(list.frame.maxY, panelFrame.maxY + 1,
                                 "provider list viewport extends below the panel")

        // Scroll the outer list to the last provider. A clipped VStack failed
        // this forever; a real scroll viewport makes the last footer hittable.
        let lastFooter = copies.element(boundBy: copies.count - 1)
        for _ in 0..<30 where !lastFooter.isHittable {
            postScrollDown(in: list.frame)
            usleep(20_000)
        }
        XCTAssertTrue(lastFooter.isHittable, "last provider footer is not reachable by scrolling")

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

    /// Scrolling while text streams must keep the outer list viewport inside the
    /// window while still allowing the last provider to become reachable.
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
        let list = app.scrollViews["results.listScroll"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))

        // The seeded stream starts at 3s; scroll without a pause across it.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            postScrollDown(in: list.frame)
            usleep(16_000)
            XCTAssertLessThanOrEqual(list.frame.maxY, panel(app).frame.maxY + 1,
                                     "result-list viewport escaped the panel")
        }

        let lastFooter = footers.element(boundBy: footers.count - 1)
        XCTAssertTrue(waitUntil(timeout: 3) { lastFooter.isHittable },
                      "last provider did not become reachable while scrolling")
    }

    /// Height stays frozen only while the mouse is held. On release normal
    /// content fitting resumes, so short results never inherit a stale viewport.
    func testDraggingWindowToScreenEdgeFreezesOnlyTheHeldGesture() {
        let text = String(
            repeating: "流式翻译过程中持续拖动窗口，结果区域仍应保持可见并可以滚动。", count: 40
        )
        let app = launch(seed: "drag while streaming", results: 1, streaming: true, resultText: text)
        let initialFrame = panel(app).frame

        // Press in the toolbar's empty center, move it to the physical bottom,
        // and keep the button held across the seeded stream (starts at 3s). A
        // small horizontal wobble keeps generating real drag events.
        let start = CGPoint(x: initialFrame.midX, y: initialFrame.minY + 16)
        let screenBottom = (NSScreen.main?.frame.height ?? initialFrame.maxY + 600) - 2
        let end = CGPoint(x: start.x, y: screenBottom)
        post(.leftMouseDown, at: start)
        let steps = 240
        for i in 1...steps {
            let progress = min(1, CGFloat(i) / 80)
            let point = CGPoint(
                x: start.x + (i.isMultiple(of: 2) ? 1 : -1),
                y: start.y + (end.y - start.y) * progress
            )
            post(.leftMouseDragged, at: point)
            usleep(10_000)
        }
        let heldFrame = panel(app).frame
        XCTAssertEqual(
            heldFrame.height, initialFrame.height, accuracy: 5,
            "streaming resized the panel while the mouse was still held"
        )
        post(.leftMouseUp, at: end)

        XCTAssertTrue(waitUntil(timeout: 5) { app.scrollViews.count >= 1 })
        XCTAssertGreaterThanOrEqual(app.scrollViews.count, 1, "the long result should remain scrollable")
    }

    /// The panel's top edge never moves on its own. Long results extend the
    /// bottom; from the normal high opening position it reaches the screen
    /// ceiling without moving the top, then the bodies scroll internally.
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

    /// The performance readout shows what the run reported. Its data path is
    /// easy to lose silently — the OpenAI dialect returns no token usage unless
    /// the request opts in, and without tokens the cost, cache and reasoning
    /// rows all vanish while the popover still looks fine.
    func testMetricsReadoutShowsWhatTheRunReported() {
        let app = launch(seed: "metrics", results: 1)
        let gauge = app.buttons.matching(identifier: "result.metrics").firstMatch
        XCTAssertTrue(gauge.waitForExistence(timeout: 10), "no metrics gauge in the card header")
        gauge.click()

        for label in ["总耗时", "Token", "成本", "思考 Token", "缓存命中", "连接", "流式", "实际模型"] {
            XCTAssertTrue(
                app.staticTexts[label].waitForExistence(timeout: 3),
                "the readout is missing its \(label) row"
            )
        }
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

    /// One scroll-down tick over the middle of `frame`, as a real HID event.
    private func postScrollDown(in frame: CGRect) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0
        ) else { return }
        event.location = CGPoint(x: frame.midX, y: frame.midY)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - LLM performance readout

    func testMetricsButtonOpensPerformancePopover() {
        let app = launch(seed: "measure me", results: 1)

        let metrics = app.buttons["result.metrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 10),
                      "the LLM performance gauge should appear on a completed run")

        metrics.click()

        // The popover surfaces the headline stats: a throughput number in tok/s
        // and the first-token label. Static text is exposed to XCUITest.
        XCTAssertTrue(waitUntil(timeout: 3) {
            app.staticTexts["输出速度"].exists && app.staticTexts["首 Token"].exists
        }, "clicking the gauge should open the performance popover")
        XCTAssertTrue(app.staticTexts["总耗时"].exists,
                      "the popover should list total time")
    }

    // MARK: - Re-translation resets a reused card's height

    func testReTranslationResetsCardHeightToCompactPlaceholder() {
        // A card is keyed by its (stable) engine id, so SwiftUI reuses the same
        // card view across translations and its tracked body-height @State
        // survives. The regression: after a long result, starting a new
        // translation showed the "翻译中…" placeholder still at the previous
        // result's tall height. The placeholder must open compact.
        let longResult = String(
            repeating: "重复翻译前的长译文，占满卡片并把面板撑到接近上限。", count: 40)
        let app = launch(seed: "source text", results: 1, resultText: longResult)

        // The single long result grows the card (and panel) tall.
        XCTAssertTrue(waitUntil(timeout: 5) { self.panel(app).frame.height > 500 },
                      "a long completed result should grow the panel tall (was \(panel(app).frame.height))")
        let tallHeight = panel(app).frame.height

        // Re-seed to the loading placeholder on the SAME card id (a re-translate).
        let reseed = app.buttons["uitest.reseedStreaming"]
        XCTAssertTrue(reseed.waitForExistence(timeout: 5))
        reseed.click()

        // The reused card must collapse back to the compact placeholder height,
        // not keep the prior result's tall height.
        XCTAssertTrue(waitUntil(timeout: 5) { self.panel(app).frame.height < tallHeight - 150 },
                      "re-translation left the placeholder at the previous result's height (still \(panel(app).frame.height), was \(tallHeight))")
        XCTAssertLessThan(panel(app).frame.height, 360,
                          "the loading placeholder card should be compact (panel \(panel(app).frame.height))")
    }
}

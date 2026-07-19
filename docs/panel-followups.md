# Panel follow-ups (handoff)

Two known issues left after the page-mode performance rework (commit `4890085`).
Both are **panel-level / timing** interactions, not regressions from that commit.
The perf goal is already done: page mode renders in a TextKit2 `NSTextView`
(`PageReaderView` in `Sources/UI/Panel/StreamingTextView.swift`), scrolls
smoothly, streams interleaved, no frame drops.

> **Testing note.** This app is an `LSUIElement` menu-bar agent; the desktop
> computer-use automation can't target it, so verification is manual. Fast path
> to reproduce with seeded content (no network):
> ```
> launchctl setenv UITEST_INPUT "<long multi-line text>"
> launchctl setenv UITEST_RESULTS "1"
> open -a DuoTranslator --args -uiTest        # seeds a panel + 1 long fake result
> ```
> (see `AppDelegate` `-uiTest` branch → `PanelController.uiTestPresent` →
> `TranslationRunController.uiTestSeedResults`). Or just run the app and
> translate a long passage. `Log.app`/`Log.capture` are at `.debug`; stream with
> `/usr/bin/log stream --predicate 'subsystem=="dev.bobby.DuoTranslator"' --level debug`.

---

## 1. Dragging any scrollbar drags the whole window

**Symptom.** In page mode (and **also in the compact result cards** — confirmed
pre-existing), grabbing the vertical scrollbar and dragging moves the entire
panel window instead of scrolling. Leaves a drag "afterimage."

**Root cause.** The panel opts every non-interactive area into window-dragging:
`PanelController` sets `panel.isMovableByWindowBackground = true` and
`DraggableHostingView.mouseDownCanMoveWindow = true`
(`Sources/UI/Panel/PanelController.swift`). A drag that isn't claimed by an
interactive control is treated as a window move; the scrollbar/scroll area gets
caught by this.

**What was tried (did NOT work).** Subclassing the scroll view and the scroller
to override `mouseDownCanMoveWindow = false` (`PageScrollView`,
`NonDraggingScroller` in `StreamingTextView.swift`). No effect — the views are
hosted inside SwiftUI, and an intermediate SwiftUI/hosting layer still reports
the area as window-draggable (and/or the overlay scroller's hit-testing bypasses
the override).

**Suggested approach.** Rework the panel's drag model instead of per-view opt-out:
- Turn OFF `isMovableByWindowBackground` (and drop `DraggableHostingView`'s
  `mouseDownCanMoveWindow = true`).
- Make **only the toolbar/top chrome** initiate window drags — e.g. an AppKit
  view in the toolbar region whose `mouseDragged` calls
  `window.performDrag(with:)`, or a dedicated drag handle. The input editor,
  language bar, result cards, and page-mode reader must never start a window
  drag.
- Verify: dragging the toolbar moves the window; dragging a scrollbar or the
  result/reader body scrolls/selects and does **not** move the window.
- This affects the whole panel (cards included), so re-check: outside-click
  dismissal, pinning, and that empty chrome you *do* want draggable still is.

Relevant: `Sources/UI/Panel/PanelController.swift` (`DraggableHostingView`,
`isMovableByWindowBackground`), `Sources/UI/Panel/PanelToolbarView.swift`.

---

## 2. Opening page mode dips short, then grows

**Symptom.** Toggling into page mode, the panel briefly shrinks to a short
height and then grows to fit the content (a visible "short → tall" flash on
first open).

**Root cause.** Switching to page mode runs `applyModeWidth` → `refit`
(`PanelController`), and `refit` sizes the window from the **stale
`resultHeightMeasured`** left over from card mode (often shorter). A tick later
`PageModeView` reports the taller page height and the window grows. Net: shrink
then grow.

**What was tried (helped, but the window-level dip remains).** `PageModeView`'s
`contentHeight` was made optional so the output *fills the budget* until the
first real measurement, and `PageReaderView` now delivers the measured height on
the next runloop tick (mutating SwiftUI `@State` inside the update pass was
being dropped). That fixed the *content-area* narrowness, but the *window*
still dips because `refit` uses the previous measurement during the switch.

**Suggested approach.** During a mode switch, don't shrink to the prior
measurement:
- On `viewModel.pageMode` change, invalidate `resultHeightMeasured` (e.g. to a
  sentinel) and have `refit` hold the current height / fill the budget until a
  fresh page-mode height arrives, then grow-then-cap.
- Or drive the window height purely off the newly-shown content's reported
  height, ignoring the outgoing mode's cached value for that first pass.

Relevant: `Sources/UI/Panel/PanelController.swift` (`applyModeWidth`, `refit`,
`resultHeightMeasured`, the `onModeChange` wiring),
`Sources/UI/Panel/PageModeView.swift` (`onResultsHeightChange`,
`reportedHeight`, `outputDisplayed`).

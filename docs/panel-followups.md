# Panel follow-ups

**2026-07-22 (2): the closing fit opens the panel; budget is water-filled.**
Two follow-ups on top of "placement never shrinks":

- **Mid-height stall on completion** — a panel parked low fills only the room
  below its top edge, so long content ended clipped at a "middle" height with
  the whole upper screen unused, one manual drag away from readable. Now the
  fit ceiling is phase-dependent (`PanelLayout.fitHeightCeiling`): while any
  engine streams, growth stays inside the down-room (screen bottom → internal
  scroll, unchanged); when the last engine settles, one closing fit may use
  the whole usable screen — the dragOrigin safety net turns the overflow into
  a bottom-anchored lift of the top edge, so the panel opens to its content's
  height automatically. The settle transition is triggered explicitly (a
  Combine watch on every run's `$state`): when the last engine finishes with
  its card already capped, no geometry callback would fire otherwise.
- **Budget stranded by the even split** — `perCardBodyMax` gave every card
  `budget/n` even when a short or collapsed card used a fraction of its share,
  so the clipped card next to it could never reach the free space. Replaced by
  water-filling (`PanelLayout.cardBodyCaps`): cards report a known natural
  body height (`ResultCardView.naturalBodyNeed` → `ResultListView.bodyNeeds`);
  a settled, fully-visible card consumes only `max(floor, need)`, a collapsed
  card consumes nothing, and everyone unknown (streaming, or clipped — a
  ceiling-stopped measurement is a lower bound) splits the remainder evenly,
  so concurrent streams keep equal shares and a fast engine can't starve a
  slow one.

  Two hard-won stability rules inside that split:
  - **The clip signal must come from the measurer.** Inferring "fully
    visible" by comparing the measurement to the rendered height mistakes a
    ceiling-stopped measurement (which parks exactly at the ceiling) for a
    complete one — the clipped card got classified as a tiny known need and
    its neighbour took the whole budget (one giant card + one starved one).
    `StreamingTextView` now reports `onContentClippedChange`
    (= its own `reachedHeightCeiling`) alongside the height, and the card
    passes its true render ceiling (`PanelLayout.bodyRenderCeiling`, ratchet
    and dragged height included) as `heightCeiling`. A binding divider height
    is the exception: consumption is pinned, so the rendered height is the
    known need.
  - **Auto growth is bounded by `PanelLayout.maxAutoBodyHeight` (360).**
    Water-filling can hand one card the whole budget (neighbours collapsed or
    short) and the closing fit can open the window to the whole screen —
    combined, a single long output grew into a near-fullscreen card. Any
    card's auto cap stops there and the body scrolls; the dragged divider
    still customizes per engine within the bound. Two expanded cards rarely
    hit it (their fair shares stay below).
  - **A satisfied card is granted `need + one line` (hysteresis).** Granting
    exactly `need` parks the ceiling on the measurement; the next report
    reads as ceiling-stopped, the need flips back to unknown, the split
    reverts, and the window oscillates a few points at ~30Hz (`refit` looped
    forever between two heights — the "jitter while dragging"). The slack
    keeps a satisfied ceiling strictly above its content so the
    classification has a fixed point; `cardBodyCaps` deducts what it grants.

**2026-07-22: placement never shrinks.** Follow-up invariant to the drag work
below: **window placement never shrinks any rendered height** — only content
changes (shorter translation, new run, mode switch), an explicit gesture
(divider drag, double-click reset), or a smaller screen's ceiling can.

- The flush-bottom shrink was *not* the allowance formula itself: with the
  window fully on screen, `roomBelowTop ≥ height` always holds. It was the
  even split — at flush bottom the budget converges to exactly the rendered
  stack, `perCardBodyMax` redistributes it evenly, and with unequal cards the
  taller card gets clipped toward the mean, re-reports shorter, the window
  shrinks, the budget shrinks, and the cycle iterates down (equal-height cards
  are a fixed point, which is why it looked intermittent). Fix: a ratchet on
  the per-card cap (`PanelLayout.effectiveBodyCap`) — a shrinking cap stops
  future growth but never claws back what a card already shows;
  `min(displayed, measured)` releases it as soon as the content itself gets
  shorter. The divider clamp uses the same effective cap.
- `allowedFitHeight` additionally floors on `currentHeight`, covering the
  paths where `roomBelowTop` genuinely dips below the window height (screen
  straddling, Dock re-show, external moves).
- Top-edge jumps and post-drag flicker were downstream of the same shrink:
  once placement can't shrink anything, the settle refit recomputes exactly
  the current height and the 4pt jitter guard turns it into zero frame
  changes. No top-edge special case exists or is needed.
- Accepted consequences: dragging up lets clipped content grow (one-way
  ratchet — dragging back down keeps the achieved height), and typing at the
  bottom yields room via the outer list scrollbar instead of squeezing card
  bodies.

**2026-07-19: resolved.** Final design, after a long lesson: **streaming never
drives layout.**

- **Scrollbar drag moved the window** — root cause was the opt-*out* drag
  model: `isMovableByWindowBackground = true` + hosting-view
  `mouseDownCanMoveWindow` treated any unclaimed drag (including on
  scrollbars) as a window move, and per-view opt-outs were ignored inside the
  hosting hierarchy. Now opt-*in*: window-background dragging is off, and the
  only drag region is the toolbar strip via `WindowDragHandle`
  (`performDrag(with:)`) behind the toolbar buttons in `PanelRootView`.
- **Panel bounced/jumped while streaming** — resolved by removing layout from
  the streaming path entirely (not by tuning resize rules, which was tried at
  length and always left some bounce): compact cards reserve a stable,
  line-aligned body viewport (`PanelLayout.stableBodyHeight`); streamed text
  only mutates text storage and scrolls inside it. Window height changes only
  with input size, card count, expanded thinking, and page mode.
- **Page-mode switch flashed short → tall** — height reports are tagged with
  the mode that produced them (`acceptResultHeight`), the last good height is
  cached per mode + runGeneration (settled runs install width+height in one
  undisplayed frame update), an unmeasured page stays at its compact floor,
  and each entry into page mode gets a fresh SwiftUI identity
  (`pageModePresentationID`) so a detached backing layer can't flash.
- **Page mode stopped updating mid-stream / showed truncated text** — the
  page reader now binds directly to the streaming model (append-only, like
  the cards) instead of re-rendering an attributed snapshot per SwiftUI
  update; bilingual mode shows the complete original + complete translation
  as independent blocks (`PageModeLayout.textBlocks`), never truncating one
  side to the other's paragraph count.

## Debug hooks

Distributed notifications (post via `swift -e` — the osascript JXA form
silently fails), for driving the panel remotely over SSH:

```
dev.bobby.duo.debug.translate   # object: source text; empty → built-in sample
dev.bobby.duo.debug.pageMode    # toggle page mode
dev.bobby.duo.debug.pin         # toggle pin (keeps panel open across clicks)
dev.bobby.duo.debug.close       # close the panel
dev.bobby.duo.debug.movePanel   # object: "bottom" (default) / "top" / "mid" — park the panel there
dev.bobby.duo.debug.openSettings
dev.bobby.duo.debug.dumpState
```

```
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.bobby.duo.debug.translate"), object: nil, userInfo: nil, deliverImmediately: true)'
```

Logs are `.debug` level (not persisted — use `log stream`, not `log show`):

```
/usr/bin/log stream --predicate 'subsystem=="dev.bobby.DuoTranslator"' --level debug
```

UI-test seeding (no network): `UITEST_INPUT` + `UITEST_RESULTS`, plus
`UITEST_STREAMING=1` to leave seeded cards in the no-content loading state.

> **Testing note.** This app is an `LSUIElement` menu-bar agent; desktop
> computer-use automation can't target it. For visual verification, record
> with CleanShot and analyze frames / slit-scans (ffmpeg `crop` + `tile`).

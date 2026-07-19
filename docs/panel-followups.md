# Panel follow-ups

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

# OCR: open the panel immediately + special image/recognition view

## Context

Two problems with today's screenshot-OCR flow (`⌥S` 截图翻译 / `⌥⇧S` 截图取字):

1. **The panel appears too late.** `AppCoordinator.runOCR` (`Sources/App/AppCoordinator.swift:79`) captures the region, then `await provider.recognize(image)` **before** ever calling `panel.showInput`. So after the crosshair closes the user stares at nothing until OCR (which can be a slow network call for the LLM-vision provider) fully returns. Every other flow (划词 / plain input) shows the window first and streams into it — OCR is the odd one out.

2. **There is no OCR-specific view.** The captured `CGImage` is fed to `recognize` and immediately discarded (`ScreenshotCapturer` deletes the temp file on return; the image is a local var in `runOCR`). Nothing in the UI ever shows the image or a "recognizing" state — OCR text just silently lands in the input box.

**Goal (per user):** open the panel the instant the region is captured, and add a special OCR card — **left: the captured image, right: 识别中… → recognized text** — with the recognized text still flowing into the normal translate pipeline. Confirmed decisions: the OCR card is a **new card at the top of the results area while the existing input box is kept** (recognized text fills the input box too), and for `⌥S` **translation still auto-fires** the moment recognition completes.

## Approach

Retain the captured image in a new `OCRSession` observable, present the panel right after capture with the session in a `.recognizing` phase, then fill in text / start translation once `recognize` returns. Render the session as a two-column card at the top of `ResultListView`, above the engine result cards.

### 1. New model: `OCRSession` — `Sources/UI/Panel/OCRSession.swift` (new file)

```swift
@MainActor final class OCRSession: ObservableObject {
    let image: NSImage
    enum Phase: Equatable { case recognizing, done, empty, failed(String) }
    @Published var phase: Phase = .recognizing
    @Published var text: String = ""
    /// Optional action button for the failed/empty state (e.g. 打开系统设置 for a
    /// missing Screen Recording grant) — self-contained so we never route OCR
    /// errors through `showNotice`, which would clear the OCR card.
    @Published var action: PanelNoticeAction?
    init(image: NSImage) { self.image = image }
}
```
`PanelNoticeAction` already exists in `PanelViewModel.swift` — reuse it.

### 2. `PanelViewModel` — add the session

Add `@Published var ocr: OCRSession?` to `Sources/UI/Panel/PanelViewModel.swift`. That's the only view-model change; `translate()` / `startRun` are untouched (recognized text goes through `inputText` exactly as today).

### 3. `PanelController` — present-first for OCR — `Sources/UI/Panel/PanelController.swift`

- Extract the on-screen presentation tail of `showInput` (from `if !panel.isVisible, viewModel.run.runs.isEmpty { centerOnActiveScreen() }` through the final `refit()`, including `viewModel.pageMode = false`) into a private `presentPanel()` helper.
- `showInput(prefill:autoTranslate:)`: set `viewModel.ocr = nil` near the top (so 划词 / plain-input / notice flows drop a stale OCR card), configure input as today, call `presentPanel()`, then the `autoTranslate` branch.
- New `showOCR(image: NSImage) -> OCRSession`: clears `inputText` + `run.clear()` + `clearNotice()`, sets `viewModel.ocr = OCRSession(image:)`, calls `presentPanel()`, returns the session. No flicker (session is set before the panel is ordered front, not via a second update).
- `close()`: also `viewModel.ocr = nil`, so a dismissed session can't be applied after `recognize` returns.

### 4. `AppCoordinator.runOCR` — reorder — `Sources/App/AppCoordinator.swift:79`

```swift
private func runOCR(autoTranslate: Bool) {
    Task { @MainActor in
        do {
            let result = try await ScreenshotCapturer.captureRegion()
            guard case .image(let image) = result else { return }   // crosshair stays FIRST
            let session = panel.showOCR(image: NSImage(cgImage: image,
                                                       size: NSSize(width: image.width, height: image.height)))
            let provider = OCRFactory.makeProvider(settings: .shared, keychain: .shared)
            do {
                let text = try await provider.recognize(image)
                guard panel.viewModel.ocr === session else { return }   // dismissed / superseded
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    session.phase = .empty
                    if !PermissionCenter.hasScreenCapture {
                        session.action = PanelNoticeAction(title: "打开系统设置") {
                            PermissionCenter.openScreenCaptureSettings()
                        }
                    }
                    return
                }
                session.text = trimmed
                session.phase = .done
                panel.viewModel.inputText = text          // keep raw text for the input box
                if autoTranslate { panel.viewModel.translate() }
            } catch {
                guard panel.viewModel.ocr === session else { return }
                session.phase = .failed(error.localizedDescription)
                session.action = Self.settingsAction(for: error)   // reuse existing helper
            }
        } catch {
            panel.showNotice(error.localizedDescription, action: Self.settingsAction(for: error))
        }
    }
}
```
The outer `catch` (capture failure, before any panel) keeps the old `showNotice` path. Errors *after* the panel is up live on the session card, never `showNotice` (which would wipe the card). `panel.viewModel` is already accessible (`let viewModel` on `PanelController`).

### 5. New view: `OCRCardView` — `Sources/UI/Panel/OCRCardView.swift` (new file)

`@ObservedObject var session: OCRSession`. An `HStack` inside the same rounded `.thinMaterial` card chrome used by `ResultCardView` (copy the `.background(RoundedRectangle…)` + `.overlay(strokeBorder)` block for visual consistency):

- **Left:** `Image(nsImage: session.image).resizable().aspectRatio(contentMode: .fit)` capped to ~`maxHeight: 120`, ~`maxWidth: 150`, rounded corners.
- **Right (switch on `session.phase`):**
  - `.recognizing`: `ProgressView().controlSize(.small)` + `Text("识别中…")` (`.secondary`).
  - `.done`: the recognized text in a bounded `ScrollView { Text(session.text).textSelection(.enabled) }` (cap height so a long capture scrolls) + a `CopyButton(text: session.text, …)` (reuse the existing component from `ResultCardView`'s footer).
  - `.empty`: `Text("没有识别到文字。")` + optional `session.action` button.
  - `.failed(let m)`: `Text(m)` (`.secondary`) + optional `session.action` button.

### 6. `ResultListView` — render the OCR card on top — `Sources/UI/Panel/ResultListView.swift`

In `content`, handle the OCR session so the card shows even before any translation run exists:
- If `viewModel.ocr != nil`: a `VStack(spacing: 8)` with `OCRCardView(session:)` first, then `ForEach(run.runs) { ResultCardView(...) }` (empty during recognition, fills in once `translate()` runs). Keep the existing `.padding(.horizontal, 12).padding(.vertical, 10)`.
- Else keep the current empty-placeholder / `ForEach` branches unchanged.
- `perCardMaxBody`: when `viewModel.ocr != nil`, subtract an estimated OCR-card height (image cap ~120 + card chrome ≈ 150) from the `budget` so, at the window's ceiling, the OCR card doesn't push the last engine card's footer off-screen. The whole `ResultListView` is geometry-measured, so the window still grows to fit the added card automatically — this only rebalances the *capped* case.

The card only renders in card mode (`ResultListView`); page mode (`PageModeView`) is a manual per-session toggle for viewing one translation large and is out of scope for the OCR card.

### Reused pieces (do not re-implement)
- `PanelNoticeAction`, `AppCoordinator.settingsAction(for:)`, `PermissionCenter.hasScreenCapture` / `openScreenCaptureSettings()`.
- `CopyButton`, and the rounded-material card chrome from `ResultCardView`.
- The existing `translate()` → `run.start` pipeline (unchanged) for turning the recognized text into engine cards.

## Files

- **New:** `Sources/UI/Panel/OCRSession.swift`, `Sources/UI/Panel/OCRCardView.swift`
- **Modified:** `Sources/App/AppCoordinator.swift`, `Sources/UI/Panel/PanelController.swift`, `Sources/UI/Panel/PanelViewModel.swift`, `Sources/UI/Panel/ResultListView.swift`

## Build note (XcodeGen)

Two new files are added, so regenerate the project before building:
`xcodegen generate`, then the usual Release build + install to `/Applications` (no TCC reset — signing identity is unchanged). See the project's build/install memory.

## Verification

Build, install, then exercise each path manually (the region crosshair can't be driven by tests, so this is hands-on):
1. **Immediate open:** trigger `⌥S` over on-screen text. Confirm the panel appears the moment the crosshair closes, showing the captured image on the left and `识别中…` on the right — *before* recognition finishes. When it lands: recognized text appears in the right column **and** the input box, then translation cards stream in below the OCR card.
2. **取字 only:** `⌥⇧S` — same image + recognized text, text in the input box, **no** auto-translation. Editing the input + Enter still translates, OCR card stays on top.
3. **Empty:** capture a blank/empty region → OCR card shows `没有识别到文字。`; with Screen Recording denied, the 打开系统设置 button appears on the card.
4. **Error:** point OCR at a misconfigured LLM-vision provider → card shows `.failed` message (+ settings button for permission errors); the panel stays up (no `showNotice` wipe).
5. **Dismiss race:** trigger `⌥S`, immediately click outside to close while recognizing → the late `recognize` result is dropped (identity guard), no stray window/translation.
6. Regression: 划词 / plain input open a panel with **no** OCR card (stale card cleared by `showInput`).

Optional: add an OCR UI-test seam mirroring `uiTestSeedResults` (inject a session + sample `NSImage`) if we want the card's sizing under the existing `-uiTest` harness — not required for the feature.

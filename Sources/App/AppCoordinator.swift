import AppKit

/// Central entry point for every user-triggered flow. Owns the long-lived
/// controllers (panel, settings window) and routes hotkey / menu actions.
@MainActor
final class AppCoordinator {
    private var settingsWindow: SettingsWindowController?
    private var statsWindow: StatsWindowController?
    private lazy var panel = PanelController()
    private lazy var imagePreview: ImagePreviewController = {
        let controller = ImagePreviewController()
        // Closing the viewer re-arms the panel's outside-click dismissal.
        controller.onClose = { [weak self] in self?.panel.setSuppressOutsideClose(false) }
        return controller
    }()

    // MARK: - Actions

    func openInputWindow() {
        panel.showInput()
    }

    /// Build and lay out the panel during launch-idle so the first selection
    /// translation doesn't pay the lazy-construction + first-layout cost. Purely
    /// off-screen — the window is never shown, so there's no visible flash.
    func prewarmPanel() {
        panel.prewarm()
    }

    /// UI-test entry point (guarded by the `-uiTest` launch argument in
    /// `AppDelegate`): shows the panel with deterministic seed text — and, when
    /// `resultCount > 0`, that many fake completed result cards — so tests can
    /// drive sizing/feedback/scrolling without simulating hotkeys or the network.
    func uiTestShowPanel(
        seed: String,
        resultCount: Int = 0,
        streaming: Bool = false,
        resultText: String? = nil
    ) {
        panel.uiTestPresent(
            input: seed,
            resultCount: resultCount,
            streaming: streaming,
            resultText: resultText
        )
    }

    /// Shared entry for selection / OCR flows (M2 / M3).
    func translateText(_ text: String) {
        panel.showInput(prefill: text, autoTranslate: true)
    }

    func translateSelection() {
        Task { @MainActor in
            let t0 = Date()
            Log.capture.debug("划词: 触发")
            do {
                // Text selection takes priority: capture it (AX first, ⌘C fallback)
                // before showing the panel so focus is still in the source app.
                let text = try await SelectedTextProvider.capture()
                Log.capture.debug("划词: 捕获完成→显示面板, 触发起共 \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
                translateText(text)
            } catch SelectedTextProvider.CaptureError.accessibilityDenied {
                PermissionCenter.requestAccessibility()
                panel.showNotice(
                    "需要辅助功能权限，才能读取其他 app 中选中的文本。授权后请重启 DuoTranslator 再试。",
                    action: PanelNoticeAction(title: "打开系统设置") {
                        PermissionCenter.openAccessibilitySettings()
                    }
                )
            } catch SelectedTextProvider.CaptureError.empty {
                // No selectable text — only now judge the clipboard: if it holds an
                // image (and not text), 划词 falls back to OCR. This keeps a stale
                // clipboard image from hijacking every 划词 over a real selection.
                if let cgImage = ClipboardImage.read() {
                    Log.capture.debug("划词: 无选中文本，剪贴板是图片 → OCR")
                    beginOCR(cgImage: cgImage, autoTranslate: true)
                } else {
                    panel.showNotice(SelectedTextProvider.CaptureError.empty.localizedDescription ?? "")
                }
            } catch {
                panel.showNotice(error.localizedDescription)
            }
        }
    }

    func ocrTranslate() {
        runOCR(autoTranslate: true)
    }

    func ocrToInput() {
        runOCR(autoTranslate: false)
    }

    private func runOCR(autoTranslate: Bool) {
        Task { @MainActor in
            do {
                let result = try await ScreenshotCapturer.captureRegion()
                // Keep the crosshair capture FIRST: no window may appear over the
                // region-selection overlay. Once a region is picked, show the OCR
                // panel immediately (image column + recognizing state) and
                // recognize with it up — text and translation then fill in place.
                guard case .image(let image) = result else { return }
                beginOCR(cgImage: image, autoTranslate: autoTranslate)
            } catch {
                // Capture failed before any panel — the notice path is still right.
                panel.showNotice(error.localizedDescription, action: Self.settingsAction(for: error))
            }
        }
    }

    /// Present the OCR panel for a captured image and start recognition. Shared by
    /// the screenshot flow and the 划词 clipboard-image shortcut.
    private func beginOCR(cgImage: CGImage, autoTranslate: Bool) {
        let session = panel.showOCR(cgImage: cgImage)
        // 重新识别 re-runs recognition on the same image (never auto-translating —
        // the user is reviewing, not committing). Weak `session`: the closures are
        // stored on the session itself.
        session.reRecognize = { [weak self, weak session] in
            guard let self, let session else { return }
            self.recognize(into: session, autoTranslate: false)
        }
        // Tapping the thumbnail opens the full-size viewer; suppress the panel's
        // outside-click close while it's up.
        session.onView = { [weak self, weak session] in
            guard let self, let session else { return }
            self.panel.setSuppressOutsideClose(true)
            self.imagePreview.show(session.image)
        }
        recognize(into: session, autoTranslate: autoTranslate)
    }

    /// Recognize `session`'s image and drive its phase. On success the text lands
    /// in the panel's input box (single source of truth) and, when `autoTranslate`,
    /// translation starts in place — the image column stays put, cards stream below
    /// the input. Errors stay on the OCR column (never `showNotice`). Guards on the
    /// panel's current session so a dismissed / superseded run can't apply.
    private func recognize(into session: OCRSession, autoTranslate: Bool) {
        session.phase = .recognizing
        session.action = nil
        // Clear any prior text so a 重新识别 doesn't show the last result behind
        // the "识别中…" placeholder while the new pass runs.
        session.text = ""
        panel.viewModel.inputText = ""
        panel.viewModel.ocrRecognizing = true
        Task { @MainActor in
            let provider = OCRFactory.makeProvider(settings: .shared, keychain: .shared)
            do {
                let text = try await provider.recognize(session.cgImage)
                // Superseded by a new flow while recognizing: leave the flag to
                // the new owner, drop this result.
                guard panel.viewModel.ocr === session else { return }
                panel.viewModel.ocrRecognizing = false
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.capture.debug("OCR: 识别完成 \(trimmed.count, privacy: .public) 字")
                guard !trimmed.isEmpty else {
                    // No text can mean an empty selection OR a blank/redacted
                    // screenshot from a missing Screen Recording grant. Only in
                    // the latter case offer the System Settings jump.
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
                panel.viewModel.inputText = trimmed
                // The editor was disabled while recognizing; focus it now so the
                // recognized text is immediately editable (the 取字 review path).
                panel.viewModel.focusToken += 1
                if autoTranslate { panel.viewModel.translate() }
            } catch {
                guard panel.viewModel.ocr === session else { return }
                panel.viewModel.ocrRecognizing = false
                session.phase = .failed(error.localizedDescription)
                session.action = Self.settingsAction(for: error)
            }
        }
    }

    /// Attach a "打开系统设置" button to permission-related capture failures so the
    /// notice is a one-tap fix rather than a dead end.
    private static func settingsAction(for error: Error) -> PanelNoticeAction? {
        if case ScreenshotCapturer.ScreenshotError.permissionNeeded = error {
            return PanelNoticeAction(title: "打开系统设置") {
                PermissionCenter.openScreenCaptureSettings()
            }
        }
        return nil
    }

    /// Debug hooks (distributed notifications, see `AppDelegate`): drive the
    /// panel remotely over SSH — page mode / pin toggles and close, so scripted
    /// runs can exercise the same paths as toolbar clicks.
    func debugTogglePageMode() {
        panel.viewModel.togglePageMode()
    }

    func debugTogglePin() {
        panel.viewModel.isPinned.toggle()
    }

    func debugClosePanel() {
        panel.close()
    }

    func debugMovePanel(_ spec: String) {
        panel.debugMove(spec)
    }

    /// Debug hook (`dev.bobby.duo.debug.ocrTest`): render a known sample image
    /// and run an LLM vision provider against it end-to-end, logging the result
    /// or error. Uses the real keychain key, so it exercises the exact path a
    /// screenshot would — without needing to drive the crosshair UI. `model`
    /// (the notification object) overrides the engine's model, e.g. "gpt-4o".
    func debugOCRTest(model: String?) async {
        guard let image = Self.debugSampleOCRImage() else {
            Log.app.error("ocrTest: 无法生成样本图片")
            return
        }
        let settings = SettingsStore.shared
        guard let provider = settings.providers.first(where: { $0.kind == .openAICompat }) else {
            Log.app.error("ocrTest: 没有 openAICompat 供应商")
            return
        }
        let ocrModel = (model?.isEmpty == false) ? model! : settings.ocrModel
        let profile = EngineProfile(provider: provider, model: ocrModel)
        let key = KeychainStore.shared.secret(for: provider.id) ?? ""
        Log.app.error("ocrTest: 供应商=\(provider.name, privacy: .public) model=\(profile.model, privacy: .public) keyLen=\(key.count)")

        let ocr = LLMVisionOCRProvider(profile: profile, apiKey: key)
        do {
            let text = try await ocr.recognize(image)
            Log.app.error("ocrTest: 成功 \(text.count) 字 → \(text, privacy: .public)")
        } catch {
            Log.app.error("ocrTest: 失败 → \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A crisp white card with mixed Latin/CJK/digits for the OCR debug hook.
    private static func debugSampleOCRImage() -> CGImage? {
        let text = "DuoTranslator OCR test\nHello 世界 12345\nThe quick brown fox."
        let size = NSSize(width: 720, height: 240)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            in: NSRect(x: 24, y: 24, width: size.width - 48, height: size.height - 48),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 40),
                .foregroundColor: NSColor.black,
            ]
        )
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }

    func openStats() {
        if statsWindow == nil {
            statsWindow = StatsWindowController()
        }
        statsWindow?.show()
    }
}

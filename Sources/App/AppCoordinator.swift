import AppKit

/// Central entry point for every user-triggered flow. Owns the long-lived
/// controllers (panel, settings window) and routes hotkey / menu actions.
@MainActor
final class AppCoordinator {
    private var settingsWindow: SettingsWindowController?
    private var statsWindow: StatsWindowController?
    private lazy var panel = PanelController()

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
                // Capture before showing the panel so focus is still in the
                // source app.
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
                guard case .image(let image) = result else { return }
                let settings = SettingsStore.shared
                let provider = OCRFactory.makeProvider(settings: settings, keychain: .shared)
                let text = try await provider.recognize(image)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.capture.debug("OCR: 识别完成 \(trimmed.count, privacy: .public) 字")
                guard !trimmed.isEmpty else {
                    // No text can mean an empty selection OR a blank/redacted
                    // screenshot from a missing Screen Recording grant. Only in
                    // the latter case point at System Settings.
                    if PermissionCenter.hasScreenCapture {
                        panel.showNotice("没有识别到文字。")
                    } else {
                        panel.showNotice(
                            "没有识别到文字。若截图为黑屏，请授予屏幕录制权限并重启 DuoTranslator。",
                            action: PanelNoticeAction(title: "打开系统设置") {
                                PermissionCenter.openScreenCaptureSettings()
                            }
                        )
                    }
                    return
                }
                panel.showInput(prefill: text, autoTranslate: autoTranslate)
            } catch {
                panel.showNotice(error.localizedDescription, action: Self.settingsAction(for: error))
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
        guard var profile = settings.engineProfiles.first(where: { $0.kind == .openAICompat }) else {
            Log.app.error("ocrTest: 没有 openAICompat 引擎")
            return
        }
        if let model, !model.isEmpty { profile.model = model }
        let key = KeychainStore.shared.secret(for: profile.id) ?? ""
        Log.app.error("ocrTest: 引擎=\(profile.name, privacy: .public) model=\(profile.model, privacy: .public) keyLen=\(key.count)")

        let provider = LLMVisionOCRProvider(profile: profile, apiKey: key)
        do {
            let text = try await provider.recognize(image)
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

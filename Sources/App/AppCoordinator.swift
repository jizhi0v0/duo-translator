import AppKit

/// Central entry point for every user-triggered flow. Owns the long-lived
/// controllers (panel, settings window) and routes hotkey / menu actions.
@MainActor
final class AppCoordinator {
    private var settingsWindow: SettingsWindowController?
    private lazy var panel = PanelController()

    // MARK: - Actions

    func openInputWindow() {
        panel.showInput()
    }

    /// Shared entry for selection / OCR flows (M2 / M3).
    func translateText(_ text: String) {
        panel.showInput(prefill: text, autoTranslate: true)
    }

    func translateSelection() {
        Task { @MainActor in
            do {
                // Capture before showing the panel so focus is still in the
                // source app.
                let text = try await SelectedTextProvider.capture()
                translateText(text)
            } catch SelectedTextProvider.CaptureError.accessibilityDenied {
                PermissionCenter.requestAccessibility()
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
                let text = try await TextRecognizer.recognize(
                    image,
                    languages: settings.ocrLanguages,
                    mergeParagraphs: settings.ocrMergesLines
                )
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    panel.showNotice("没有识别到文字。")
                    return
                }
                panel.showInput(prefill: text, autoTranslate: autoTranslate)
            } catch {
                panel.showNotice(error.localizedDescription)
            }
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }
}

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
        Log.app.info("translateSelection triggered")
        // M2: capture selected text, then translate.
    }

    func ocrTranslate() {
        Log.app.info("ocrTranslate triggered")
        // M3: screenshot -> OCR -> auto translate.
    }

    func ocrToInput() {
        Log.app.info("ocrToInput triggered")
        // M3: screenshot -> OCR -> editable input.
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }
}

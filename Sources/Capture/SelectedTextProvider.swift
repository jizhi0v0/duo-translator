import AppKit
import Carbon.HIToolbox

@MainActor
enum SelectedTextProvider {
    enum CaptureError: LocalizedError {
        case accessibilityDenied
        case secureInput
        case empty

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "需要辅助功能权限才能读取选中文本。"
            case .secureInput:
                return "当前处于安全输入状态（如密码框），无法读取选中文本。"
            case .empty:
                return "没有读取到选中的文本。"
            }
        }
    }

    /// Capture the current selection from the frontmost app.
    /// Must run *before* our panel is shown so focus is still in the source app.
    static func capture() async throws -> String {
        guard PermissionCenter.isAccessibilityTrusted else {
            throw CaptureError.accessibilityDenied
        }

        if let text = cleaned(AXSelectionReader.selectedText()) {
            // Web views (Electron/Chromium) expose a multi-line selection through
            // AX as a single flattened line. When the AX text looks like that —
            // no line breaks but long enough to plausibly span lines — take a ⌘C
            // instead, which keeps the breaks. `PasteboardCopyFallback` only
            // returns on a fresh copy (the change count bumped), so it's the
            // current selection; prefer it whenever it comes back with breaks.
            if !text.contains("\n"), text.count > 30,
               let copied = cleaned(await PasteboardCopyFallback.capture()),
               copied.contains("\n") {
                return copied
            }
            return text
        }

        // Chromium/Electron: enable their AX tree, then retry once.
        if let app = NSWorkspace.shared.frontmostApplication {
            AXSelectionReader.pokeManualAccessibility(pid: app.processIdentifier)
            try? await Task.sleep(for: .milliseconds(120))
            if let text = cleaned(AXSelectionReader.selectedText()) {
                return text
            }
        }

        if IsSecureEventInputEnabled() {
            throw CaptureError.secureInput
        }

        if let text = cleaned(await PasteboardCopyFallback.capture()) {
            return text
        }
        throw CaptureError.empty
    }

    /// Strip any U+FFFD the capture paths couldn't repair, drop trailing
    /// whitespace / blank lines the selection often carries (internal line
    /// breaks are kept), and treat empty results as no capture at all.
    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let sanitized = CapturedTextSanitizer.sanitized(text)
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard !sanitized.isEmpty else { return nil }
        return sanitized
    }
}

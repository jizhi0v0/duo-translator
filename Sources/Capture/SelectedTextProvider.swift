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

        if let text = AXSelectionReader.selectedText(), !text.isEmpty {
            return text
        }

        // Chromium/Electron: enable their AX tree, then retry once.
        if let app = NSWorkspace.shared.frontmostApplication {
            AXSelectionReader.pokeManualAccessibility(pid: app.processIdentifier)
            try? await Task.sleep(for: .milliseconds(120))
            if let text = AXSelectionReader.selectedText(), !text.isEmpty {
                return text
            }
        }

        if IsSecureEventInputEnabled() {
            throw CaptureError.secureInput
        }

        if let text = await PasteboardCopyFallback.capture(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        throw CaptureError.empty
    }
}

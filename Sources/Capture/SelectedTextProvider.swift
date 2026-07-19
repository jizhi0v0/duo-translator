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
        // Timing instrumentation: log which path is taken and how long each
        // stage costs, so the selection-capture latency can be profiled live.
        let t0 = Date()
        func ms(_ from: Date = t0) -> String {
            String(format: "%.1f", Date().timeIntervalSince(from) * 1000)
        }

        guard PermissionCenter.isAccessibilityTrusted else {
            throw CaptureError.accessibilityDenied
        }

        let axStart = Date()
        let axRaw = AXSelectionReader.selectedText()
        Log.capture.debug("划词: AX 读取 \(ms(axStart), privacy: .public)ms, 命中=\(axRaw != nil, privacy: .public)")

        if let text = cleaned(axRaw) {
            // Web views (Electron/Chromium) expose a multi-line selection through
            // AX as a single flattened line. When the AX text looks like that —
            // no line breaks but long enough to plausibly span lines — take a ⌘C
            // instead, which keeps the breaks. `PasteboardCopyFallback` only
            // returns on a fresh copy (the change count bumped), so it's the
            // current selection; prefer it whenever it comes back with breaks.
            let wStart = Date()
            let webCtx = !text.contains("\n") && text.count > 30 && AXSelectionReader.focusedIsWebContext()
            Log.capture.debug("划词: web 判定 \(ms(wStart), privacy: .public)ms = \(webCtx, privacy: .public)")
            if webCtx {
                let cStart = Date()
                let copied = cleaned(await PasteboardCopyFallback.capture())
                Log.capture.debug("划词: web-view ⌘C 复核 \(ms(cStart), privacy: .public)ms, 多行=\(copied?.contains("\n") == true, privacy: .public)")
                if let copied, copied.contains("\n") {
                    Log.capture.debug("划词: 完成[AX+⌘C 多行] 总 \(ms(), privacy: .public)ms, \(copied.count, privacy: .public) 字, 换行\(copied.filter(\.isNewline).count, privacy: .public)")
                    return copied
                }
            }
            Log.capture.debug("划词: 完成[AX 直读] 总 \(ms(), privacy: .public)ms, \(text.count, privacy: .public) 字, 换行\(text.filter(\.isNewline).count, privacy: .public)")
            return text
        }

        // Chromium/Electron: enable their AX tree, then retry once.
        if let app = NSWorkspace.shared.frontmostApplication {
            let pokeStart = Date()
            AXSelectionReader.pokeManualAccessibility(pid: app.processIdentifier)
            // Cheap insurance only: some Electron apps expose their AX tree the
            // instant it's poked. Apps that never populate (e.g. Claude) would
            // otherwise burn the whole window here for nothing, so cap it low
            // (~40ms) and let them fall straight through to the fast ⌘C path.
            var pokeText: String?
            for i in 1...2 {
                try? await Task.sleep(for: .milliseconds(20))
                if let t = cleaned(AXSelectionReader.selectedText()) {
                    Log.capture.debug("划词: poke 命中于第 \(i, privacy: .public) 次 (~\(i * 20, privacy: .public)ms)")
                    pokeText = t
                    break
                }
            }
            if let text = pokeText {
                Log.capture.debug("划词: 完成[AX poke 重试] 总 \(ms(), privacy: .public)ms (poke+轮询 \(ms(pokeStart), privacy: .public)ms), \(text.count, privacy: .public) 字, 换行\(text.filter(\.isNewline).count, privacy: .public)")
                return text
            }
            Log.capture.debug("划词: AX poke 重试无果 \(ms(pokeStart), privacy: .public)ms")
        }

        if IsSecureEventInputEnabled() {
            Log.capture.debug("划词: 安全输入态,放弃 总 \(ms(), privacy: .public)ms")
            throw CaptureError.secureInput
        }

        let pbStart = Date()
        if let text = cleaned(await PasteboardCopyFallback.capture()) {
            Log.capture.debug("划词: 完成[⌘C 兜底] 总 \(ms(), privacy: .public)ms (⌘C \(ms(pbStart), privacy: .public)ms), \(text.count, privacy: .public) 字, 换行\(text.filter(\.isNewline).count, privacy: .public)")
            return text
        }
        Log.capture.debug("划词: 空,失败 总 \(ms(), privacy: .public)ms")
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

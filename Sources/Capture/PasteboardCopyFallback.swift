import AppKit
import Carbon.HIToolbox

/// Last-resort selection capture: simulate ⌘C, read the pasteboard, then put
/// the user's original clipboard back.
@MainActor
enum PasteboardCopyFallback {
    static func capture() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let previousChangeCount = pasteboard.changeCount

        postCmdC()

        // The source app may still be writing when changeCount first bumps
        // (clearContents lands before the data does), so a first read can see
        // nil or partially-decoded text with U+FFFD in it — keep re-reading
        // briefly instead of trusting it.
        var copied: String?
        var readsAfterChange = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(10))
            guard pasteboard.changeCount != previousChangeCount else { continue }
            let text = pasteboard.string(forType: .string)
            if let text, !text.isEmpty, !CapturedTextSanitizer.containsReplacementCharacter(text) {
                copied = text
                break
            }
            copied = text ?? copied
            readsAfterChange += 1
            if readsAfterChange >= 8 { break }
        }

        if pasteboard.changeCount != previousChangeCount {
            // Restore the user's clipboard as a detached side effect — the caller
            // already has the text, so blocking the return on the ~100ms
            // settle+restore just adds latency to every capture. The clipboard
            // holds the copied selection for that brief window, then flips back.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                pasteboard.clearContents()
                if !saved.isEmpty {
                    pasteboard.writeObjects(saved)
                }
            }
        }
        return copied
    }

    /// Deep-copy pasteboard items — originals are invalidated by clearContents.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func postCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

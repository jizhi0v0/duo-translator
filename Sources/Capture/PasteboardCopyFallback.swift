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

        var copied: String?
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(10))
            if pasteboard.changeCount != previousChangeCount {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        if pasteboard.changeCount != previousChangeCount {
            // Give the source app a beat to finish writing before restoring,
            // then put the user's clipboard back.
            try? await Task.sleep(for: .milliseconds(100))
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved)
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

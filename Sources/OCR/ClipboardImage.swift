import AppKit

/// Reads an image off the general pasteboard for the 划词 shortcut: when the
/// clipboard holds an image (and not text), 划词 runs OCR on it instead of
/// capturing a text selection.
@MainActor
enum ClipboardImage {
    /// A fully-decoded `CGImage` if the clipboard currently holds an image and
    /// **no** plain-text string (a text clipboard must still go through the normal
    /// selection → translate path). Nil otherwise.
    static func read() -> CGImage? {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let hasImage = types.contains(.png) || types.contains(.tiff)
        guard hasImage, !types.contains(.string) else { return nil }
        guard let image = NSImage(pasteboard: pb) else { return nil }
        // Force a full render to CGImage now (Vision needs materialized pixels).
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

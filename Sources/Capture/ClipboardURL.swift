import AppKit

/// Reads a web URL off the general pasteboard for the 链接翻译 flow: when the
/// clipboard holds text that is a single http/https URL, that link is fetched
/// and translated. Mirrors `ClipboardImage` — a narrow, typed read of the
/// current clipboard so the coordinator can branch on it.
@MainActor
enum ClipboardURL {
    /// The clipboard's string as an http/https `URL`, or nil when the clipboard
    /// holds no string, or a string that isn't a single web URL.
    static func read() -> URL? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        return parse(raw)
    }

    /// Pure parse, split out for tests: trims, rejects multi-token / whitespace-
    /// laden strings, and requires an http/https scheme with a non-empty host.
    static func parse(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A URL has no interior whitespace; a sentence that merely contains a
        // link is not treated as a link.
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

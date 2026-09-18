import Foundation

/// Tidies the paragraph text handed back by the in-page Readability extraction
/// before it becomes the translation input: trims the whole thing, drops
/// trailing/leading blank lines, and collapses runs of 3+ blank lines to one —
/// so page mode's paragraph pairing (`\n`-delimited, blanks ignored) stays clean
/// without ballooning the input box. Pure and unit-tested.
enum ArticleText {
    static func normalize(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var out: [String] = []
        var pendingBlanks = 0
        for line in lines {
            if line.isEmpty {
                pendingBlanks += 1
                continue
            }
            // Between paragraphs keep at most one blank line.
            if !out.isEmpty, pendingBlanks > 0 { out.append("") }
            pendingBlanks = 0
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Drops the site nav that agent-browser's `read` prints before the article:
    /// its output leads with nav lines (Home / Sign In / Advertisement / …) then
    /// the page's H1 as `# Title`. Trimming to the first `# ` heading removes that
    /// preamble generically (no per-site rules). Returns the input unchanged when
    /// there's no H1, so pages without one aren't accidentally emptied.
    static func articleBody(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
        }) else { return s }
        return lines[idx...].joined(separator: "\n")
    }

    /// The first markdown `# ` heading in the text — agent-browser's `read`
    /// output leads the article body with the page's H1 as `# Title`, after any
    /// nav lines. Used as the link chip's title. Nil when there's no heading.
    static func firstHeading(_ s: String) -> String? {
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                let title = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return nil
    }
}

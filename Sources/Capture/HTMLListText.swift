import Foundation

/// Plain text for a copied HTML fragment, with list markers kept.
///
/// Chromium's `public.utf8-plain-text` drops `<ol>`/`<ul>` markers, so a list
/// copied from a web view (Claude desktop, Chrome) arrives as bare lines and
/// reaches the translator without its `1.` / `•`. The `public.html` flavor
/// still carries the structure; this flattens it to text the way the page
/// reads. `NSAttributedString(html:)` would do the same but spins up WebKit on
/// the main thread (~300-500ms), far too slow for the capture path.
enum HTMLListText {
    /// Text for `html`, or nil when the fragment has no list — then the
    /// pasteboard's own plain text is already faithful and is kept instead.
    static func text(fromHTML html: String) -> String? {
        guard html.range(of: "<li", options: .caseInsensitive) != nil else { return nil }
        var builder = Builder()
        for token in tokenize(html) {
            builder.consume(token)
        }
        let result = builder.finish()
        return result.isEmpty ? nil : result
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case open(name: String, attributes: String)
        case close(name: String)
        case text(String)
    }

    /// A forgiving tag scanner: clipboard HTML is a fragment with unclosed
    /// `<meta>`/`<br>` and the like, so it isn't parseable as XML.
    static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var rest = Substring(html)
        while !rest.isEmpty {
            guard let lt = rest.firstIndex(of: "<") else {
                tokens.append(.text(String(rest)))
                break
            }
            if lt > rest.startIndex {
                tokens.append(.text(String(rest[rest.startIndex..<lt])))
            }
            let tagStart = rest[lt...]
            if tagStart.hasPrefix("<!--") {
                guard let end = tagStart.range(of: "-->") else { break }
                rest = tagStart[end.upperBound...]
                continue
            }
            guard let gt = tagStart.firstIndex(of: ">") else {
                // A stray `<` with no tag after it is just text.
                tokens.append(.text(String(tagStart)))
                break
            }
            let inner = tagStart[tagStart.index(after: lt)..<gt]
            rest = tagStart[tagStart.index(after: gt)...]

            let isClose = inner.hasPrefix("/")
            let body = isClose ? inner.dropFirst() : inner
            let nameEnd = body.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? body.endIndex
            let name = body[..<nameEnd].lowercased()
            guard !name.isEmpty, name.first!.isLetter else { continue } // `<!doctype>` etc.

            if isClose {
                tokens.append(.close(name: name))
            } else {
                tokens.append(.open(name: name, attributes: String(body[nameEnd...])))
                // Raw-text elements: skip their content wholesale.
                if name == "script" || name == "style" {
                    if let end = rest.range(of: "</\(name)", options: .caseInsensitive) {
                        rest = rest[end.lowerBound...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                }
            }
        }
        return tokens
    }

    // MARK: - Builder

    private struct Builder {
        private struct ListFrame {
            let ordered: Bool
            var next: Int
        }

        private var out = ""
        /// Line breaks owed before the next visible content (0, 1 or 2).
        private var pendingBreaks = 0
        /// A list marker owed at the start of the next visible content.
        private var pendingMarker: String?
        private var lists: [ListFrame] = []
        private var preDepth = 0
        private var skipDepth = 0
        /// Inside `<li>`, paragraphs are lines, not blank-line-separated blocks.
        private var liDepth = 0

        private static let paragraphBlocks: Set<String> = [
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "table", "hr",
        ]
        private static let lineBlocks: Set<String> = [
            "div", "section", "article", "header", "footer", "main", "nav", "aside",
            "figure", "figcaption", "tr", "dl", "dt", "dd", "details", "summary",
        ]

        mutating func consume(_ token: Token) {
            switch token {
            case let .open(name, attributes):
                open(name, attributes: attributes)
            case let .close(name):
                close(name)
            case let .text(raw):
                guard skipDepth == 0 else { return }
                text(HTMLListText.decodeEntities(raw))
            }
        }

        private mutating func open(_ name: String, attributes: String) {
            switch name {
            case "script", "style", "head", "title":
                skipDepth += 1
            case "br":
                // A `<br>` breaks even an otherwise empty line.
                flush()
                out += "\n"
            case "ol", "ul":
                requestBreak(liDepth > 0 || !lists.isEmpty ? 1 : 2)
                let start = name == "ol" ? HTMLListText.startAttribute(attributes) ?? 1 : 1
                lists.append(ListFrame(ordered: name == "ol", next: start))
            case "li":
                liDepth += 1
                requestBreak(1)
                let indent = String(repeating: "  ", count: max(lists.count - 1, 0))
                if let i = lists.indices.last {
                    if lists[i].ordered {
                        pendingMarker = indent + "\(lists[i].next). "
                        lists[i].next += 1
                    } else {
                        pendingMarker = indent + "• "
                    }
                } else {
                    pendingMarker = "• "
                }
            case "td", "th":
                if !out.isEmpty, !out.hasSuffix("\n"), pendingBreaks == 0 { out += "\t" }
            default:
                if name == "pre" { preDepth += 1 }
                blockBoundary(name)
            }
        }

        private mutating func close(_ name: String) {
            switch name {
            case "script", "style", "head", "title":
                skipDepth = max(skipDepth - 1, 0)
            case "ol", "ul":
                if !lists.isEmpty { lists.removeLast() }
                requestBreak(liDepth > 0 || !lists.isEmpty ? 1 : 2)
            case "li":
                liDepth = max(liDepth - 1, 0)
                pendingMarker = nil
                requestBreak(1)
            default:
                if name == "pre" { preDepth = max(preDepth - 1, 0) }
                blockBoundary(name)
            }
        }

        private mutating func blockBoundary(_ name: String) {
            if Self.paragraphBlocks.contains(name) {
                requestBreak(liDepth > 0 ? 1 : 2)
            } else if Self.lineBlocks.contains(name) {
                requestBreak(1)
            }
        }

        private mutating func requestBreak(_ n: Int) {
            pendingBreaks = max(pendingBreaks, n)
        }

        private mutating func text(_ s: String) {
            if preDepth > 0 {
                guard !s.isEmpty else { return }
                flush()
                out += s
                return
            }
            // Collapse whitespace the way a browser renders it.
            let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let leading = s.first?.isWhitespace == true
            let trailing = s.last?.isWhitespace == true
            if collapsed.isEmpty {
                // Whitespace-only run: a space between inline content, nothing
                // at a line start or where a break is already owed.
                if leading, pendingBreaks == 0, pendingMarker == nil, !atLineStart { out += " " }
                return
            }
            if leading, pendingBreaks == 0, pendingMarker == nil, !atLineStart { out += " " }
            flush()
            out += collapsed
            if trailing { out += " " }
        }

        private var atLineStart: Bool { out.isEmpty || out.hasSuffix("\n") || out.hasSuffix(" ") }

        /// Emit owed breaks and marker before visible content.
        private mutating func flush() {
            if pendingBreaks > 0, !out.isEmpty {
                while out.hasSuffix(" ") { out.removeLast() }
                let have = out.reversed().prefix(while: { $0 == "\n" }).count
                if have < pendingBreaks {
                    out += String(repeating: "\n", count: pendingBreaks - have)
                }
            }
            pendingBreaks = 0
            if let marker = pendingMarker {
                out += marker
                pendingMarker = nil
            }
        }

        func finish() -> String {
            out.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    var l = Substring(line)
                    while l.last == " " || l.last == "\t" { l = l.dropLast() }
                    return String(l)
                }
                .joined(separator: "\n")
                .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Helpers

    static func startAttribute(_ attributes: String) -> Int? {
        guard let match = attributes.range(
            of: #"start\s*=\s*["']?(-?\d+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return Int(attributes[match].filter { $0.isNumber || $0 == "-" })
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "middot": "·", "bull": "•", "copy": "©",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let name = after[after.startIndex..<semi]
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    decoded = namedEntities[String(name)]
                }
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        out += rest
        return out
    }
}

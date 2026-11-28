import Foundation

/// The shared inline Markdown policy for chat blocks and plain session excerpts.
public func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    for run in parsed.runs {
        guard let link = run.link, link.scheme == nil,
              var components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              components.host == nil, components.path.hasPrefix("/") else { continue }
        // A Markdown absolute path needs a file scheme before macOS can open it.
        components.scheme = "file"
        components.host = ""
        if let file = components.url { parsed[run.range].link = file }
    }
    return parsed
}

/// The block structure of an agent's Markdown message: headings, list items,
/// fenced code, tables and paragraphs. SwiftUI's `Text` renders only inline Markdown, so
/// without this a heading reads as "## Summary" and a list as dashes.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// `marker` is "•" for an unordered item or the number with its dot.
    case listItem(marker: String, text: String, indent: Int)
    /// `language` is the fence's info word ("swift", "bash"), nil when it has none.
    case code(String, language: String? = nil)
    case paragraph(String)
    case table(MarkdownTable)
    case blockquote(String)
    case thematicBreak

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var state = ParserState()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            state.consume(lines: lines, index: &index)
            index += 1
        }
        state.finish()
        return state.blocks
    }

    private struct ParserState {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?
        var language: String?

        mutating func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
            if !quote.isEmpty { blocks.append(.blockquote(quote.joined(separator: "\n"))) }
            quote = []
        }

        mutating func finish() {
            // An unclosed fence still shows its code.
            if let open = code { blocks.append(.code(open.joined(separator: "\n"), language: language)) }
            flush()
        }

        mutating func consume(lines: [String], index: inout Int) {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if consumeFence(line: line, trimmed: trimmed) { return }
            if let quoted = MarkdownBlock.blockquoteLine(line) {
                if !paragraph.isEmpty { flush() }
                quote.append(quoted)
                return
            }
            if !quote.isEmpty { flush() }
            if let table = MarkdownTable.parse(lines, index: &index) {
                flush()
                blocks.append(.table(table))
            } else if trimmed.isEmpty {
                flush()
            } else if paragraph.isEmpty, MarkdownBlock.isThematicBreak(line) {
                blocks.append(.thematicBreak)
            } else if let block = MarkdownBlock.heading(trimmed) ?? MarkdownBlock.listItem(line) {
                flush()
                blocks.append(block)
            } else {
                paragraph.append(line)
            }
        }

        private mutating func consumeFence(line: String, trimmed: String) -> Bool {
            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    flush()
                    code = []
                    let info = trimmed.dropFirst(3).split(separator: " ").first.map(String.init) ?? ""
                    language = info.isEmpty ? nil : info
                }
                return true
            }
            if code != nil {
                code?.append(line)
                return true
            }
            return false
        }
    }

    static func blockquoteLine(_ line: String) -> String? {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return nil }
        let rest = line.dropFirst(spaces)
        guard rest.first == ">" else { return nil }
        let after = rest.dropFirst()
        if after.isEmpty { return "" }
        guard after.first == " " else { return nil }
        return String(after.dropFirst())
    }

    static func isThematicBreak(_ line: String) -> Bool {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return false }
        let rest = line.dropFirst(spaces)
        guard let marker = rest.first, marker == "-" || marker == "*" || marker == "_" else { return false }
        var count = 0
        for char in rest {
            if char == marker {
                count += 1
            } else if char != " " && char != "\t" {
                return false
            }
        }
        return count >= 3
    }

    /// GitHub-flavored alert marker on the opening line of a blockquote.
    public enum Alert: String, Equatable, Sendable {
        case note, tip, important, warning, caution

        public var title: String { rawValue.capitalized }

        public static func extract(_ raw: String) -> (Alert?, String) {
            let firstEnd = raw.firstIndex(of: "\n") ?? raw.endIndex
            let first = raw[..<firstEnd].trimmingCharacters(in: .whitespaces)
            let kind: Alert?
            switch first.uppercased() {
            case "[!NOTE]": kind = .note
            case "[!TIP]": kind = .tip
            case "[!IMPORTANT]": kind = .important
            case "[!WARNING]": kind = .warning
            case "[!CAUTION]": kind = .caution
            default: kind = nil
            }
            guard let kind else { return (nil, raw) }
            guard firstEnd < raw.endIndex else { return (kind, "") }
            let rest = raw[raw.index(after: firstEnd)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (kind, rest)
        }
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }

    static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count / 2
        let body = line.drop { $0 == " " }
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return .listItem(marker: "\u{2022}", text: String(body.dropFirst(2)), indent: indent)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, body.dropFirst(digits.count).hasPrefix(". ") {
            return .listItem(marker: digits + ".", text: String(body.dropFirst(digits.count + 2)), indent: indent)
        }
        return nil
    }
}

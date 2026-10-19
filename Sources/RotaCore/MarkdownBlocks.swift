import Foundation

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

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var language: String?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if let table = MarkdownTable.parse(lines, index: &index) {
                flush()
                blocks.append(.table(table))
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let heading = Self.heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if let item = Self.listItem(line) {
                flush()
                blocks.append(item)
            } else {
                paragraph.append(line)
            }
        }
        // An unclosed fence still shows its code.
        if let open = code { blocks.append(.code(open.joined(separator: "\n"), language: language)) }
        flush()
        return blocks
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

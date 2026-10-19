import Foundation

/// A pipe table. Inline Markdown is kept for the renderer; body rows match the header's column count.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Sendable {
        case left, center, right
    }

    public let headers: [String]
    public let alignments: [Alignment]
    public let rows: [[String]]

    public init(headers: [String], alignments: [Alignment], rows: [[String]]) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
    }

    /// Consumes the header, delimiter and body; leaves the caller on the last consumed line.
    static func parse(_ lines: [String], index: inout Int) -> MarkdownTable? {
        guard index + 1 < lines.count,
              let header = cells(lines[index]),
              let alignments = delimiter(lines[index + 1]),
              header.count == alignments.count else { return nil }
        index += 2
        var rows: [[String]] = []
        while index < lines.count, let cells = cells(lines[index]) {
            rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count)))
            index += 1
        }
        index -= 1
        return MarkdownTable(headers: header, alignments: alignments, rows: rows)
    }

    /// Only unescaped pipes split cells. Escaped pipes also work inside code spans.
    static func cells(_ line: String) -> [String]? {
        let source = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var separators = 0
        for character in source {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                separators += 1
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        guard separators > 0 else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if source.hasPrefix("|") { cells.removeFirst() }
        if cell.isEmpty, source.hasSuffix("|") { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    static func delimiter(_ line: String) -> [Alignment]? {
        guard let cells = cells(line) else { return nil }
        var alignments: [Alignment] = []
        for cell in cells {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .right) : .left)
        }
        return alignments
    }
}

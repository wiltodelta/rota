import RotaCore
import SwiftUI

/// Shared column widths and wrapping cells keep a table readable inside a chat bubble.
/// Wide tables scroll locally without widening the transcript.
struct MarkdownTableView: View {
    @Environment(\.interfaceScale) private var metrics
    let table: MarkdownTable
    let text: ChatTextSettings
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        let cells = ([table.headers] + table.rows).map { $0.map(inlineMarkdown) }
        let widths = columnWidths(cells)
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                row(cells[0], header: true, widths: widths)
                ForEach(1..<cells.count, id: \.self) { index in
                    row(cells[index], header: false, widths: widths)
                }
            }
            .frame(width: widths.reduce(0, +))
            .background(Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: metrics.points(6)))
            .overlay {
                RoundedRectangle(cornerRadius: metrics.points(6))
                    .strokeBorder(Color.primary.opacity(0.18))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityIdentifier("markdownTable")
    }

    private func columnWidths(_ cells: [[AttributedString]]) -> [CGFloat] {
        var lengths = Array(repeating: 0, count: table.headers.count)
        for row in cells {
            for column in row.indices { lengths[column] = max(lengths[column], row[column].characters.count) }
        }
        return Self.columnWidths(contentLengths: lengths, availableWidth: availableWidth,
                                 fontSize: text.effectiveSize(ChatTextSettings.baseSize), padding: metrics.points(20))
    }

    static func columnWidths(contentLengths: [Int], availableWidth: CGFloat,
                             fontSize: CGFloat, padding: CGFloat) -> [CGFloat] {
        // Compact values keep their natural width. Longer text shares the remaining
        // space by content length, damped by a square root to balance wrapped row height.
        let natural = contentLengths.map { length in
            let characters = CGFloat(max(length, 1))
            return fontSize * (length <= 12 ? max(characters * 0.65, 1) : 2 * sqrt(characters)) + padding
        }
        let flexible = contentLengths.indices.filter { contentLengths[$0] > 12 }
        guard !flexible.isEmpty else { return natural }
        let compactWidth = contentLengths.indices.filter { contentLengths[$0] <= 12 }
            .reduce(CGFloat.zero) { $0 + natural[$1] }
        let desiredWidth = flexible.reduce(CGFloat.zero) { $0 + natural[$1] }
        let minimumScale = flexible.map { (fontSize * 6 + padding) / natural[$0] }.max() ?? 1
        // If fitting would squeeze a column below readable word width, scroll the
        // table instead. Keep the unequal proportions at every interface scale.
        let scale = max((availableWidth - compactWidth) / desiredWidth, minimumScale)
        return contentLengths.indices.map { column in
            contentLengths[column] <= 12 ? natural[column] : natural[column] * scale
        }
    }

    private func row(_ cells: [AttributedString], header: Bool, widths: [CGFloat]) -> some View {
        return HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                let alignment = alignment(table.alignments[column])
                Text(cells[column])
                    .font(header ? text.body.weight(.semibold) : text.body)
                    .lineSpacing(text.bodyLineSpacing)
                    .multilineTextAlignment(alignment.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, metrics.points(10))
                    .padding(.vertical, metrics.points(8))
                    .frame(width: widths[column], alignment: alignment.frame)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(header ? Color.primary.opacity(0.065) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private func alignment(_ alignment: MarkdownTable.Alignment) -> (text: TextAlignment, frame: Alignment) {
        switch alignment {
        case .left: (.leading, .leading)
        case .center: (.center, .center)
        case .right: (.trailing, .trailing)
        }
    }

}

import RotaCore
import SwiftUI

/// An agent message drawn block by block: headings, lists and code as such,
/// inline Markdown (bold, code spans, links) inside each.
struct MarkdownText: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let source: String

    var body: some View {
        let text = model.chatText
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            ForEach(Array(MarkdownProse.parts(MarkdownBlock.parse(source)).enumerated()), id: \.offset) { _, part in
                switch part {
                case .prose(let blocks):
                    ProseText(text: MarkdownProse.attributed(blocks, text: text, metrics: metrics))
                case .block(let block):
                    blockView(block, text: text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Code, tables and blocks that show an image, which the prose view cannot hold.
    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, text: ChatTextSettings) -> some View {
        switch block {
        case .heading(let level, let content):
            MarkdownInlineView(source: content)
                .font(text.heading(level: level))
                .padding(.top, metrics.points(4))
        case .listItem(let marker, let content, let indent):
            HStack(alignment: .firstTextBaseline, spacing: metrics.points(6)) {
                Text(marker).foregroundStyle(Color.secondaryText)
                MarkdownInlineView(source: content)
            }
            .font(text.body)
            .padding(.leading, CGFloat(indent) * 16)
        case .code(let content, let language):
            CodeBlockView(code: content, language: language)
        case .table(let table):
            MarkdownTableView(table: table, text: text)
        case .paragraph(let content):
            MarkdownInlineView(source: content).font(text.body)
        }
    }
}

/// A fenced code block as super.engineering draws one: a header with the
/// language and a Copy button over the code, which scrolls sideways rather than wrapping.
struct CodeBlockView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "Plain text")
                Spacer()
                CopyButton(text: code, help: "Copy Code")
            }
            .font(model.chatText.small)
            .foregroundStyle(Color.secondaryText)
            .padding(.horizontal, metrics.points(12))
            .padding(.vertical, metrics.points(6))
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(model.chatText.code)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(metrics.points(12))
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: metrics.points(10)))
        .overlay { RoundedRectangle(cornerRadius: metrics.points(10)).strokeBorder(Color.primary.opacity(0.06)) }
    }
}

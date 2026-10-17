import RotaCore
import SwiftUI

/// An agent message drawn block by block: headings, lists and code as such,
/// inline Markdown (bold, code spans, links) inside each.
struct MarkdownText: View {
    @Environment(AppModel.self) private var model
    let source: String

    var body: some View {
        let text = model.chatText
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(inline(content))
                        .font(text.heading(level: level))
                        .padding(.top, 4)
                case .listItem(let marker, let content, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(Color.secondaryText)
                        Text(inline(content))
                    }
                    .font(text.body)
                    .padding(.leading, CGFloat(indent) * 16)
                case .code(let content, let language):
                    CodeBlockView(code: content, language: language)
                case .paragraph(let content):
                    Text(inline(content)).font(text.body)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

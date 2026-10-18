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
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(inline(content))
                        .font(text.heading(level: level))
                        .padding(.top, metrics.points(4))
                case .listItem(let marker, let content, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: metrics.points(6)) {
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

/// A fenced code block as super.engineering draws one: a header with the
/// language and a Copy button over the code, which scrolls sideways rather than wrapping.
struct CodeBlockView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "Plain text")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(copied ? "Copied" : "Copy Code")
                .accessibilityLabel(copied ? "Copied" : "Copy Code")
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

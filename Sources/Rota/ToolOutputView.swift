import RotaCore
import SwiftUI

/// Tools keep literal text; images and edits have their own compact presentation.
struct ToolOutputView: View {
    @Environment(\.interfaceScale) private var metrics
    let item: TranscriptItem

    var body: some View {
        if let output = ToolOutput.decode(item.text) {
            VStack(alignment: .leading, spacing: metrics.points(8)) {
                ForEach(Array(output.parts.enumerated()), id: \.offset) { index, part in
                    switch part.kind {
                    case .text: CodeBox(text: part.text)
                    case .image:
                        if let url = URL(string: part.text) {
                            MarkdownImageView(reference: .init(url: url, alt: part.path ?? "Tool image"))
                                .environment(\.sessionImageItemID, item.id)
                        }
                    case .diff:
                        ToolDiffView(path: part.path ?? "File changes", diff: part.text,
                                     identifier: "toolDiff-\(item.id)-\(index)")
                    }
                }
            }
        } else {
            CodeBox(text: item.text)
        }
    }
}

private struct ToolDiffView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let path: String
    let diff: String
    let identifier: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            Button { expanded.toggle() } label: {
                HStack(spacing: metrics.points(6)) {
                    Image(systemName: "chevron.right")
                        .interfaceFont(.caption2).fontWeight(.semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(path).lineLimit(2).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, minHeight: metrics.points(28), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(model.chatText.small)
            .accessibilityLabel("File changes: " + path)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier(identifier)
            .help(path)
            if expanded {
                ScrollView(.vertical) { CodeBlockView(code: diff, language: "diff") }
                    .frame(maxHeight: metrics.points(240))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(identifier + "-body")
            }
        }
    }
}

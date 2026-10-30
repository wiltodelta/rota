import SwiftUI

/// Provider-exposed reasoning stays available without competing with the answer.
struct ReasoningView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let text: String
    var willToggle: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            Button {
                willToggle()
                expanded.toggle()
            } label: {
                HStack(spacing: metrics.points(5)) {
                    Image(systemName: "chevron.right")
                        .interfaceFont(.caption2).fontWeight(.semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Reasoning")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide reasoning" : "Show reasoning")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("reasoningDetails")
            if expanded {
                MarkdownText(source: text).textSelection(.enabled)
            }
        }
        .font(model.chatText.small)
        .foregroundStyle(Color.secondaryText)
        .accessibilityElement(children: .contain)
    }
}

struct CompatibilityNotice: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(model.chatText.small)
            .foregroundStyle(Color.secondaryText)
            .accessibilityIdentifier("harnessCompatibilityNotice")
    }
}

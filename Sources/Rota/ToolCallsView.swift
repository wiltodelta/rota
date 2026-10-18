import RotaCore
import SwiftUI

/// Presentation only: the journal keeps every call in its original position.
struct ToolCallsView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let calls: [TranscriptItem]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            Button { expanded.toggle() } label: {
                HStack(spacing: metrics.points(6)) {
                    Image(systemName: "chevron.right")
                        .interfaceFont(.caption2).fontWeight(.semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Label(calls.count == 1 ? "1 tool call" : "\(calls.count) tool calls",
                          systemImage: "wrench.and.screwdriver")
                }
                .frame(maxWidth: .infinity, minHeight: metrics.points(28), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("toolCalls-\(calls.first?.id ?? -1)")
            .help(expanded ? "Hide tool calls" : "Show tool calls")
            if expanded {
                VStack(alignment: .leading, spacing: metrics.points(8)) {
                    ForEach(calls) { call in
                        Text(call.text)
                            .font(model.chatText.smallCode)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("toolCall-\(call.id)")
                    }
                }
                .padding(.leading, metrics.points(20))
            }
        }
        .font(model.chatText.small)
        .foregroundStyle(Color.secondaryText)
    }
}

import RotaCore
import SwiftUI

/// Presentation only: the journal keeps every call in its original position.
struct ToolCallsView: View {
    @Environment(AppModel.self) private var model
    let calls: [TranscriptItem]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Label(calls.count == 1 ? "1 tool call" : "\(calls.count) tool calls",
                          systemImage: "wrench.and.screwdriver")
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("toolCalls-\(calls.first?.id ?? -1)")
            .help(expanded ? "Hide tool calls" : "Show tool calls")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calls) { call in
                        Text(call.text)
                            .font(model.chatText.smallCode)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("toolCall-\(call.id)")
                    }
                }
                .padding(.leading, 20)
            }
        }
        .font(model.chatText.small)
        .foregroundStyle(Color.secondaryText)
    }
}

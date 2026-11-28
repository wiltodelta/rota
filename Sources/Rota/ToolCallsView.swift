import RotaCore
import SwiftUI

/// Presentation only: the journal keeps every call in its original position.
struct ToolCallsView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let calls: [TranscriptItem]
    @Binding var expanded: Bool

    var body: some View {
        let rawLines = calls.filter { $0.kind == .tool }.map(\.text)
        let header = Self.descriptor(rawLines)
        let singleCodeHeader = rawLines.count == 1 && header.isCode
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            StepDisclosureButton(symbol: header.symbol, title: header.title,
                                 usesCodeFont: header.isCode, expanded: $expanded)
                .accessibilityIdentifier("toolCalls-\(calls.first?.id ?? -1)")
                .help(expanded ? "Hide tool calls" : "Show tool calls")
            if expanded {
                VStack(alignment: .leading, spacing: metrics.points(8)) {
                    ForEach(calls) { call in
                        ToolCallItemView(call: call, repeatsHeader: singleCodeHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("toolCall-\(call.id)")
                    }
                }
                .padding(.leading, metrics.points(20))
            }
        }
        .font(model.chatText.small)
        .foregroundStyle(Color.secondaryText)
    }

    struct Header {
        let symbol: String
        let title: String
        let isCode: Bool
    }

    static func descriptor(_ rawLines: [String], live: Bool = false) -> Header {
        let symbol = rawLines.isEmpty ? "wrench.and.screwdriver" : ToolStep.dominant(rawLines).symbol
        if rawLines.count == 1 {
            let concise = ToolStep.callTitle(rawLines[0])
            if let change = FileChangeTitle.title(concise, live: live) {
                return Header(symbol: symbol, title: change, isCode: false)
            }
            return Header(symbol: symbol, title: concise, isCode: true)
        }
        let title = rawLines.isEmpty ? "Tool output" : ToolStep.summary(rawLines).capitalizedFirst
        return Header(symbol: symbol, title: title, isCode: false)
    }
}

struct StepDisclosureButton: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    var symbol: String?
    let title: String
    var usesCodeFont = false
    var rowHeight: CGFloat = 28
    @Binding var expanded: Bool

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: metrics.points(6)) {
                Image(systemName: "chevron.right")
                    .interfaceFont(.caption2).fontWeight(.semibold)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: metrics.points(14))
                }
                Text(title)
                    .font(usesCodeFont ? model.chatText.smallCode : model.chatText.small)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, minHeight: metrics.points(rowHeight), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

private struct ToolCallItemView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    @State private var showParameters = false
    let call: TranscriptItem
    let repeatsHeader: Bool

    var body: some View {
        if call.kind == .output {
            ToolOutputView(item: call)
        } else {
            let presented = ToolStep.presentCall(call.text)
            let showTitle = !repeatsHeader || presented.parameters == nil || presented.title.count > 64
            VStack(alignment: .leading, spacing: metrics.points(4)) {
                if showTitle {
                    Text(presented.title)
                        .font(model.chatText.smallCode)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let parameters = presented.parameters {
                    StepDisclosureButton(title: "Parameters", rowHeight: 22, expanded: $showParameters)
                        .accessibilityIdentifier("toolParameters-\(call.id)")
                    if showParameters {
                        Text(parameters)
                            .font(model.chatText.smallCode)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, metrics.points(14))
                    }
                }
            }
        }
    }
}

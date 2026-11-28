import RotaCore
import SwiftUI

/// A routine's session history: an excerpt carries the result; metadata stays secondary.
struct SessionHistoryRow: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord

    var body: some View {
        Group {
            if record.isSkip {
                content.accessibilityElement(children: .combine)
            } else {
                Button { model.selection = .session(record.id) } label: { content }
                    .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("sessionHistory-" + record.id.uuidString)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: metrics.points(12)) {
                    date
                    Spacer(minLength: 0)
                    status
                }
                VStack(alignment: .leading, spacing: metrics.points(4)) { date; status }
            }
            SessionPreviewText(record: record)
                .interfaceFont(.body)
                .fontWeight(record.isUnread ? .medium : .regular)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sessionPreview-" + record.id.uuidString)
            HarnessMetadata(harness: record.harness, text: metadata)
                .interfaceFont(.caption)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, metrics.points(6))
        .contentShape(Rectangle())
    }

    private var date: some View {
        Text(record.startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
            .interfaceFont(.caption)
            .foregroundStyle(Color.secondaryText)
            .fixedSize()
    }

    private var status: some View {
        Label {
            Text(statusTitle)
                .foregroundStyle(needsAttention ? Color.primary : Color.secondaryText)
                .fontWeight(needsAttention ? .semibold : .regular)
        } icon: {
            Image(systemName: statusSymbol)
                .foregroundStyle(needsAttention ? Color.orange
                    : record.outcome.isFailure && !record.isSkip ? Color.errorText : Color.secondaryText)
        }
            .interfaceFont(.caption)
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }

    private var needsAttention: Bool { record.needsAttention }

    private var statusTitle: String {
        record.compactStatusTitle(canMessage: model.scheduler.canMessage(record))
    }

    private var statusSymbol: String {
        if needsAttention { return "exclamationmark.bubble.fill" }
        switch record.outcome {
        case .running: return record.terminalState == .waiting ? "terminal" : "circle.dotted"
        case .succeeded: return "checkmark.circle"
        case .cancelled: return "stop.circle"
        case .skipped: return "clock"
        default: return "exclamationmark.triangle"
        }
    }

    private var metadata: String {
        Self.metadata(for: record, models: model.settings.models)
    }

    static func metadata(for record: RunRecord, models: [Harness: [ModelOption]]) -> String {
        var parts = [record.harness.title]
        if record.reportedModel ?? record.model != nil {
            parts.append(ModelLabel.model(record: record, models: models))
        }
        if let effort = ModelLabel.effort(record) { parts.append(effort) }
        if !record.isSkip, let ended = record.endedAt {
            parts.append(Transcript.readable(seconds: max(0, Int(ended.timeIntervalSince(record.startedAt)))))
        }
        if record.trigger == .catchUp { parts.append("Catch-up") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

import RotaCore
import SwiftUI

/// A routine's session history: an excerpt carries the result; metadata stays secondary.
struct SessionHistoryRow: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    @State private var snapshot: TranscriptSnapshot?
    @State private var reader = TranscriptSessionReader()

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
        .task(id: record) {
            guard !record.isSkip, let path = record.logPath else { return }
            repeat {
                let next = await reader.read(log: URL(fileURLWithPath: path), shell: record.harness == .shell,
                                             finished: record.outcome != .running)
                guard !Task.isCancelled else { return }
                if snapshot != next { snapshot = next }
                if record.outcome != .running { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled
        }
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
            Text(verbatim: SessionPreview.text(for: record, snapshot: snapshot))
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

    private var needsAttention: Bool { record.attention != nil || record.questions?.isEmpty == false }

    private var statusTitle: String {
        if record.questions?.isEmpty == false { return "Needs your reply" }
        if record.attention != nil {
            return model.scheduler.canMessage(record) ? "Needs your reply" : "Needs your attention"
        }
        if case .launchFailed = record.outcome { return "Couldn't start" }
        if case .skipped = record.outcome { return "Skipped" }
        return record.statusTitle
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
        var parts = [record.harness.title]
        if let model = record.reportedModel ?? record.model { parts.append(model) }
        if !record.isSkip, let ended = record.endedAt {
            parts.append(Transcript.readable(seconds: max(0, Int(ended.timeIntervalSince(record.startedAt)))))
        }
        if record.trigger == .catchUp { parts.append("Catch-up") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

import AppKit
import RotaCore
import SwiftUI

/// Shared visual mapping for Schedule entries.
@MainActor
enum CalendarEntryVisual {
    /// The Schedule's records are skipped slots; Sessions shows every other run.
    static func statusTitle(for entry: CalendarEntry) -> String {
        switch entry.kind {
        case .record:
            return entry.isFrequent ? "Skipped (\(entry.count))" : "Skipped"
        case .scheduled(let paused):
            if paused {
                return entry.isFrequent ? "Paused \u{00B7} \(entry.count) runs" : "Paused"
            }
            return entry.isFrequent ? "\(entry.count) runs" : "Scheduled"
        }
    }

    static func symbol(for entry: CalendarEntry) -> String {
        switch entry.kind {
        case .record: return "clock.badge.xmark"
        case .scheduled(let paused): return paused ? "pause.circle" : entry.isFrequent ? "repeat" : "clock"
        }
    }

    static func symbolColor(for entry: CalendarEntry) -> Color {
        switch entry.kind {
        case .record: return .orange
        case .scheduled(let paused): return paused ? Color.secondaryText : Color.accentColor
        }
    }

    static func time(for entry: CalendarEntry) -> String {
        entry.start.formatted(date: .omitted, time: .shortened)
    }

    static func dayHeading(_ day: CalendarDay) -> String {
        let formatted = day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return day.isToday ? "Today \u{00B7} \(formatted)" : formatted
    }

    /// "12 runs", "3 runs · 1 skipped": what a Schedule day holds.
    static func dayCountSummary(_ day: CalendarDay) -> String {
        let skipped = day.recordedCount  // the Schedule's only records are skips
        let runs = day.scheduledCount
        var parts: [String] = []
        if runs > 0 { parts.append(runs == 1 ? "1 run" : "\(runs) runs") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A Schedule row: time, routine, its agent and schedule, and the slot's status.
struct CalendarAgendaRow: View {
    private static let horizontalPadding: CGFloat = 6
    private static let columnSpacing: CGFloat = 10
    private static let timeWidth: CGFloat = 66

    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let entry: CalendarEntry
    let action: () -> Void

    var body: some View {
        let fullTime = CalendarEntryVisual.time(for: entry)
        let status = CalendarEntryVisual.statusTitle(for: entry)
        let detail = detailText
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: metrics.points(Self.columnSpacing)) {
                    timeLabel(fullTime, fixedColumn: true)
                    VStack(alignment: .leading, spacing: metrics.points(3)) {
                        HStack(alignment: .firstTextBaseline, spacing: metrics.points(8)) {
                            titleLabel
                            Spacer(minLength: metrics.points(8))
                            statusBadge(status)
                        }
                        metadataRow(detail)
                    }
                }
                VStack(alignment: .leading, spacing: metrics.points(3)) {
                    HStack(spacing: metrics.points(8)) {
                        timeLabel(fullTime, fixedColumn: false)
                        Spacer(minLength: 0)
                        statusBadge(status)
                    }
                    titleLabel
                    metadataRow(detail)
                }
            }
            .padding(.horizontal, metrics.points(Self.horizontalPadding))
            .padding(.vertical, metrics.points(5))
            .modifier(CalendarRowHover(radius: metrics.points(6)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.routineName), \(fullTime), \(status), \(entry.harness.title)")
        .accessibilityIdentifier("scheduleEntry-" + entry.id)
    }

    private func metadataRow(_ text: String) -> some View {
        HarnessMetadata(harness: entry.harness, text: text)
            .interfaceFont(.caption)
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func timeLabel(_ text: String, fixedColumn: Bool) -> some View {
        Text(text)
            .interfaceFont(.callout)
            .monospacedDigit()
            .foregroundStyle(Color.secondaryText)
            .frame(minWidth: fixedColumn ? metrics.points(Self.timeWidth) : nil, alignment: .leading)
    }

    private var titleLabel: some View {
        Text(entry.routineName)
            .interfaceFont(.body)
            .fontWeight(.medium)
            .foregroundStyle(entry.isPaused ? Color.secondaryText : Color.primary)
            .lineLimit(1)
    }

    private func statusBadge(_ status: String) -> some View {
        Label {
            Text(status).foregroundStyle(Color.secondaryText)
        } icon: {
            Image(systemName: CalendarEntryVisual.symbol(for: entry))
                .foregroundStyle(CalendarEntryVisual.symbolColor(for: entry))
        }
        .interfaceFont(.caption)
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }

    private var detailText: String {
        // A skipped slot says why: the Mac was asleep, or the routine was already running.
        if case .skipped(let reason) = entry.record?.outcome {
            return [entry.harness.title, reason].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        }
        var parts = [
            model.scheduler.routine(entry.routineID).map {
                ModelLabel.configuration($0, models: model.settings.models)
            } ?? entry.harness.title
        ]
        if let summary = entry.scheduleSummary { parts.append(summary) }
        // A frequent schedule's row starts at its first slot; the metadata says when the day's last one is.
        if entry.isFrequent, let end = entry.end {
            parts.append("until \(end.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct CalendarRowHover: ViewModifier {
    @State private var isHovered = false
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                isHovered ? Color.primary.opacity(0.045) : Color.clear,
                in: RoundedRectangle(cornerRadius: radius)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

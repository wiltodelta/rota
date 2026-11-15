import AppKit
import RotaCore
import SwiftUI

/// Shared visual mapping for calendar entries across Week, Month and Agenda views.
@MainActor
enum CalendarEntryVisual {
    static func statusTitle(for entry: CalendarEntry, scheduler: Scheduler) -> String {
        switch entry.kind {
        case .record(let record):
            let base = record.compactStatusTitle(canMessage: scheduler.canMessage(record))
            return entry.isFrequent ? "\(base) (\(entry.count))" : base
        case .scheduled(let paused):
            if paused {
                return entry.isFrequent ? "Paused \u{00B7} \(entry.count) runs" : "Paused"
            }
            return entry.isFrequent ? "\(entry.count) runs" : "Scheduled"
        }
    }

    static func showsSpinner(for entry: CalendarEntry) -> Bool {
        guard let record = entry.record else { return false }
        return record.outcome == .running && record.terminalState != .waiting
    }

    static func symbol(for entry: CalendarEntry, prominentSuccess: Bool = true) -> String {
        switch entry.kind {
        case .record(let record):
            if record.needsAttention { return "exclamationmark.bubble.fill" }
            switch record.outcome {
            case .running: return record.terminalState == .waiting ? "terminal" : "circle.dotted"
            case .succeeded: return prominentSuccess ? "checkmark.circle.fill" : "checkmark.circle"
            case .cancelled: return "stop.circle"
            case .skipped: return "clock"
            case .failed, .launchFailed: return "xmark.circle.fill"
            case .interrupted, .timedOut: return "exclamationmark.triangle.fill"
            }
        case .scheduled(let paused):
            if paused { return "pause.circle" }
            return entry.isFrequent ? "repeat" : "clock"
        }
    }

    static func symbolColor(for entry: CalendarEntry, calmSuccess: Bool = false) -> Color {
        switch entry.kind {
        case .record(let record):
            if record.needsAttention { return .orange }
            switch record.outcome {
            case .running: return record.terminalState == .waiting ? .orange : .blue
            case .succeeded: return calmSuccess ? Color.secondaryText : .green
            case .cancelled, .skipped: return Color.secondaryText
            case .failed, .launchFailed: return Color.errorText
            case .interrupted, .timedOut: return .orange
            }
        case .scheduled(let paused):
            return paused ? Color.secondaryText : Color.accentColor
        }
    }

    private struct ChipPalette {
        let tint: Color
        let fill: Double
        let stroke: Double
    }

    static func chipStyle(for entry: CalendarEntry, hovered: Bool) -> (fill: Color, stroke: Color) {
        let palette = chipPalette(for: entry)
        return (
            palette.tint.opacity(palette.fill + (hovered ? 0.035 : 0)),
            palette.tint.opacity(palette.stroke + (hovered ? 0.12 : 0))
        )
    }

    private static func chipPalette(for entry: CalendarEntry) -> ChipPalette {
        switch entry.kind {
        case .record(let record):
            if record.needsAttention { return ChipPalette(tint: .orange, fill: 0.12, stroke: 0.38) }
            switch record.outcome {
            case .running: return ChipPalette(tint: .blue, fill: 0.10, stroke: 0.32)
            case .succeeded: return ChipPalette(tint: .primary, fill: 0.06, stroke: 0.10)
            case .cancelled, .skipped: return ChipPalette(tint: .primary, fill: 0.035, stroke: 0.08)
            case .failed, .launchFailed: return ChipPalette(tint: .errorText, fill: 0.10, stroke: 0.34)
            case .interrupted, .timedOut: return ChipPalette(tint: .orange, fill: 0.09, stroke: 0.28)
            }
        case .scheduled(let paused):
            return paused
                ? ChipPalette(tint: .primary, fill: 0.025, stroke: 0.22)
                : ChipPalette(tint: .accentColor, fill: 0.055, stroke: 0.28)
        }
    }

    static func fullTime(for entry: CalendarEntry) -> String {
        let start = entry.start.formatted(date: .omitted, time: .shortened)
        guard entry.isFrequent, let end = entry.end else { return start }
        return "\(start) - \(end.formatted(date: .omitted, time: .shortened))"
    }

    /// Separates `"project: task"` names so narrow grid cells show the distinguishing task title first.
    static func splitTitle(_ name: String) -> (scope: String?, task: String) {
        guard let range = name.range(of: ": ") else { return (nil, name) }
        let scope = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let task = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !scope.isEmpty, !task.isEmpty, scope.count <= 32 else { return (nil, name) }
        return (scope, task)
    }

    static func prioritized(_ entries: [CalendarEntry], limit: Int) -> [CalendarEntry] {
        guard entries.count > limit else { return entries }
        return entries.filter(\.isProminent) + entries.filter { !$0.isProminent }
    }

    static func dayHeading(_ day: CalendarDay) -> String {
        let formatted = day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return day.isToday ? "Today \u{00B7} \(formatted)" : formatted
    }

    static func dayCountSummary(_ day: CalendarDay) -> String {
        guard !day.entries.isEmpty else { return "Empty" }
        let recorded = day.recordedCount
        let upcoming = day.scheduledCount
        var parts: [String] = []
        if recorded > 0 { parts.append("\(recorded) recorded") }
        if upcoming > 0 { parts.append("\(upcoming) upcoming") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Compact chip for Week and Month calendar grid cells.
struct CalendarEntryChip: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let entry: CalendarEntry
    var compact = false
    let action: () -> Void

    var body: some View {
        let fullTime = CalendarEntryVisual.fullTime(for: entry)
        let compactTime = entry.isFrequent ? "\(entry.count)\u{00D7}" : fullTime
        let status = CalendarEntryVisual.statusTitle(for: entry, scheduler: model.scheduler)
        let parts = CalendarEntryVisual.splitTitle(entry.routineName)
        let muted = entry.isPaused || entry.record?.isSkip == true
        let spoken = "\(entry.routineName), \(fullTime), \(status), \(entry.harness.title)"
        Button(action: action) {
            VStack(alignment: .leading, spacing: metrics.points(1.5)) {
                HStack(spacing: metrics.points(3)) {
                    indicator
                    Text(compactTime)
                        .interfaceFont(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                Text(parts.task)
                    .interfaceFont(.caption2)
                    .fontWeight(entry.record?.isUnread == true ? .semibold : .medium)
                    .foregroundStyle(muted ? Color.secondaryText : Color.primary)
                    .lineLimit(compact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !compact, let scope = parts.scope {
                    Text(scope)
                        .font(Font(InterfaceTypography.font(size: metrics.points(9.5), semibold: false)))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, metrics.points(5))
            .padding(.vertical, metrics.points(compact ? 2.5 : 3.5))
            .modifier(CalendarChipSurface(entry: entry, radius: metrics.points(5)))
        }
        .buttonStyle(.plain)
        .help("\(entry.routineName) \u{00B7} \(fullTime) \u{00B7} \(status)")
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("calendarEntry-" + entry.id)
    }

    @ViewBuilder
    private var indicator: some View {
        if CalendarEntryVisual.showsSpinner(for: entry) {
            RunActivityIndicator()
        } else {
            Image(systemName: CalendarEntryVisual.symbol(for: entry))
                .interfaceSystemFont(size: 9, weight: .semibold)
                .foregroundStyle(CalendarEntryVisual.symbolColor(for: entry))
                .frame(width: metrics.points(10), height: metrics.points(10))
        }
    }
}

private struct CalendarChipSurface: ViewModifier {
    @State private var isHovered = false
    let entry: CalendarEntry
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let style = CalendarEntryVisual.chipStyle(for: entry, hovered: isHovered)
        content
            .background(style.fill, in: shape)
            .overlay {
                shape.strokeBorder(
                    style.stroke,
                    style: StrokeStyle(lineWidth: entry.isPaused ? 1 : 0.75, dash: entry.isPaused ? [3, 2] : [])
                )
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }
}

/// Full-width chronological row shared by Agenda mode and the Month view's selected-day detail.
struct CalendarAgendaRow: View {
    private static let horizontalPadding: CGFloat = 6
    private static let columnSpacing: CGFloat = 10
    private static let regularTimeWidth: CGFloat = 66
    private static let wideTimeWidth: CGFloat = 118

    static func dividerInset(wideTimeColumn: Bool) -> CGFloat {
        horizontalPadding + columnSpacing + (wideTimeColumn ? wideTimeWidth : regularTimeWidth)
    }

    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let entry: CalendarEntry
    var wideTimeColumn = false
    var idPrefix = "calendarAgendaEntry-"
    let action: () -> Void

    var body: some View {
        let fullTime = CalendarEntryVisual.fullTime(for: entry)
        let status = CalendarEntryVisual.statusTitle(for: entry, scheduler: model.scheduler)
        let attention = entry.record?.needsAttention == true
        let detail = detailText
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: metrics.points(Self.columnSpacing)) {
                    timeLabel(fullTime, fixedColumn: true)
                    VStack(alignment: .leading, spacing: metrics.points(3)) {
                        HStack(alignment: .firstTextBaseline, spacing: metrics.points(8)) {
                            titleLabel
                            Spacer(minLength: metrics.points(8))
                            statusBadge(status: status, needsAttention: attention)
                        }
                        metadataRow(detail)
                    }
                }
                VStack(alignment: .leading, spacing: metrics.points(3)) {
                    HStack(spacing: metrics.points(8)) {
                        timeLabel(fullTime, fixedColumn: false)
                        Spacer(minLength: 0)
                        statusBadge(status: status, needsAttention: attention)
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
        .accessibilityIdentifier(idPrefix + entry.id)
    }

    private func metadataRow(_ text: String) -> some View {
        HarnessMetadata(harness: entry.harness, text: text)
            .interfaceFont(.caption)
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func timeLabel(_ text: String, fixedColumn: Bool) -> some View {
        let width = (wideTimeColumn || entry.isFrequent) ? Self.wideTimeWidth : Self.regularTimeWidth
        return Text(text)
            .interfaceFont(.callout)
            .monospacedDigit()
            .foregroundStyle(Color.secondaryText)
            .frame(minWidth: fixedColumn ? metrics.points(width) : nil, alignment: .leading)
    }

    private var titleLabel: some View {
        Text(entry.routineName)
            .interfaceFont(.body)
            .fontWeight(entry.record?.isUnread == true ? .semibold : .medium)
            .foregroundStyle(entry.isPaused ? Color.secondaryText : Color.primary)
            .lineLimit(1)
    }

    private func statusBadge(status: String, needsAttention: Bool) -> some View {
        Label {
            Text(status)
                .foregroundStyle(needsAttention ? Color.primary : Color.secondaryText)
                .fontWeight(needsAttention ? .semibold : .regular)
        } icon: {
            if CalendarEntryVisual.showsSpinner(for: entry) {
                RunActivityIndicator()
            } else {
                Image(systemName: CalendarEntryVisual.symbol(for: entry, prominentSuccess: false))
                    .foregroundStyle(CalendarEntryVisual.symbolColor(for: entry, calmSuccess: true))
            }
        }
        .interfaceFont(.caption)
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }

    private var detailText: String {
        if let record = entry.record {
            return SessionHistoryRow.metadata(
                for: record, models: model.settings.models, includeDuration: !entry.isFrequent
            )
        }
        var parts = [
            model.scheduler.routine(entry.routineID).map {
                ModelLabel.configuration($0, models: model.settings.models)
            } ?? entry.harness.title
        ]
        if let summary = entry.scheduleSummary { parts.append(summary) }
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

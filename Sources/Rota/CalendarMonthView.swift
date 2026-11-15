import AppKit
import RotaCore
import SwiftUI

/// Seven-column Month grid with a pinned selected-day detail pane underneath.
struct CalendarMonthView: View {
    @Environment(\.interfaceScale) private var metrics
    let days: [CalendarDay]
    @Binding var selectedDay: Date
    let calendar: Calendar
    let openEntry: (CalendarEntry) -> Void

    private static let cellLimit = 2

    private var weeks: [[CalendarDay]] {
        stride(from: 0, to: days.count, by: 7).map { start in
            Array(days[start..<min(start + 7, days.count)])
        }
    }

    private var activeDay: CalendarDay? {
        days.first { $0.isCurrentMonth && calendar.isDate($0.date, inSameDayAs: selectedDay) }
            ?? days.first { calendar.isDate($0.date, inSameDayAs: selectedDay) }
            ?? days.first { $0.isToday && $0.isCurrentMonth }
            ?? days.first(where: \.isCurrentMonth)
    }

    var body: some View {
        let weekRows = weeks
        let active = activeDay
        let activeID = active?.id
        GeometryReader { geo in
            let detailHeight = min(max(geo.size.height * 0.33, metrics.points(118)), metrics.points(178))
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            VStack(spacing: 0) {
                                ForEach(Array(weekRows.enumerated()), id: \.offset) { index, week in
                                    HStack(alignment: .top, spacing: 0) {
                                        ForEach(Array(week.enumerated()), id: \.element.id) { col, day in
                                            if col > 0 { Divider() }
                                            monthCell(day, isSelected: day.id == activeID)
                                        }
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    if index < weekRows.count - 1 { Divider() }
                                }
                            }
                        } header: {
                            VStack(spacing: 0) {
                                weekdayHeader
                                Divider()
                            }
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
                .accessibilityIdentifier("calendarMonthScroll")

                if let active {
                    Divider()
                    selectedDayPane(active)
                        .frame(height: detailHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendarMonthGrid")
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.prefix(7).enumerated()), id: \.element.id) { index, day in
                if index > 0 { Divider() }
                ViewThatFits(in: .horizontal) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .interfaceFont(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .interfaceFont(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.points(5))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func monthCell(_ day: CalendarDay, isSelected: Bool) -> some View {
        let ordered = CalendarEntryVisual.prioritized(day.entries, limit: Self.cellLimit)
        let hidden = ordered.dropFirst(Self.cellLimit)
        let overflow = hidden.count
        return VStack(alignment: .leading, spacing: metrics.points(2.5)) {
            monthCellHeader(day, isSelected: isSelected, hiddenIssue: hidden.contains(where: \.isProminent))
            ForEach(ordered.prefix(Self.cellLimit)) { entry in
                CalendarEntryChip(entry: entry, compact: true) { openEntry(entry) }
            }
            if overflow > 0 {
                Button {
                    selectedDay = day.date
                } label: {
                    Text("+\(overflow) more")
                        .interfaceFont(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, metrics.points(4))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("calendarMonthOverflow-" + day.id)
            }
            Spacer(minLength: 0)
        }
        .padding(metrics.points(3.5))
        .frame(maxWidth: .infinity, minHeight: metrics.points(56), maxHeight: .infinity, alignment: .topLeading)
        .background(cellBackground(day: day, isSelected: isSelected))
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = day.date }
    }

    private func monthCellHeader(_ day: CalendarDay, isSelected: Bool, hiddenIssue: Bool) -> some View {
        let number = "\(calendar.component(.day, from: day.date))"
        return Button {
            selectedDay = day.date
        } label: {
            HStack(spacing: metrics.points(4)) {
                CalendarDayNumberBadge(number: number, isToday: day.isToday, isMuted: !day.isCurrentMonth)
                Spacer(minLength: 0)
                if hiddenIssue {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: metrics.points(6), height: metrics.points(6))
                        .help("Additional items need attention on this day")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(day))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("calendarMonthDay-" + day.id)
    }

    private func cellBackground(day: CalendarDay, isSelected: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.065) }
        if !day.isCurrentMonth { return Color.primary.opacity(0.025) }
        return Color.clear
    }

    private func dayAccessibilityLabel(_ day: CalendarDay) -> String {
        let title = day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let count = day.entries.count
        let items = count == 1 ? "1 item" : "\(count) items"
        return day.isToday ? "Today, \(title), \(items)" : "\(title), \(items)"
    }

    private func selectedDayPane(_ day: CalendarDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            selectedDayHeader(day)
            Divider().opacity(0.6)
            if day.entries.isEmpty {
                Text("No runs or scheduled slots on this day.")
                    .interfaceFont(.caption)
                    .foregroundStyle(Color.secondaryText)
                    .padding(.horizontal, metrics.points(16))
                    .padding(.vertical, metrics.points(12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                selectedDayEntries(day)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendarSelectedDay")
    }

    private func selectedDayHeader(_ day: CalendarDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.points(8)) {
            Text(CalendarEntryVisual.dayHeading(day))
                .interfaceFont(.callout)
                .fontWeight(.semibold)
                .lineLimit(1)
                .accessibilityIdentifier("calendarSelectedDayTitle")
            Spacer(minLength: metrics.points(8))
            Text(CalendarEntryVisual.dayCountSummary(day))
                .interfaceFont(.caption)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.points(16))
        .padding(.vertical, metrics.points(8))
    }

    private func selectedDayEntries(_ day: CalendarDay) -> some View {
        let wideTime = day.entries.contains(where: \.isFrequent)
        let inset = metrics.points(CalendarAgendaRow.dividerInset(wideTimeColumn: wideTime))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider()
                            .opacity(0.45)
                            .padding(.leading, inset)
                    }
                    CalendarAgendaRow(
                        entry: entry,
                        wideTimeColumn: wideTime,
                        idPrefix: "calendarMonthDetailEntry-"
                    ) {
                        openEntry(entry)
                    }
                }
            }
            .padding(.horizontal, metrics.points(10))
            .padding(.vertical, metrics.points(4))
        }
    }
}

/// Day number with true geometric circle badge when representing today.
struct CalendarDayNumberBadge: View {
    @Environment(\.interfaceScale) private var metrics
    let number: String
    let isToday: Bool
    let isMuted: Bool

    var body: some View {
        let size = metrics.points(20)
        Text(number)
            .interfaceFont(.caption)
            .monospacedDigit()
            .fontWeight(isToday ? .semibold : .regular)
            .foregroundStyle(foreground)
            .minimumScaleFactor(0.8)
            .lineLimit(1)
            .padding(.horizontal, metrics.points(isToday ? 0 : 2))
            .frame(width: isToday ? size : nil, height: size)
            .background {
                if isToday { Circle().fill(Color.accentColor) }
            }
    }

    private var foreground: Color {
        if isToday { return .onControlAccent }
        return isMuted ? Color.secondaryText : Color.primary
    }
}

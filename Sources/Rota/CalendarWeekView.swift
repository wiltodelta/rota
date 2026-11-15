import AppKit
import RotaCore
import SwiftUI

/// Seven-column 24-hour schedule grid with pinned day headers inside the scroll container
/// so column dividers stay pixel-aligned regardless of macOS scrollbar visibility.
@MainActor
struct CalendarWeekView: View {
    @Environment(\.interfaceScale) private var metrics
    @State private var overflowSelection: HourBucketID?
    let days: [CalendarDay]
    let now: Date
    let calendar: Calendar
    let openEntry: (CalendarEntry) -> Void

    private static let cellLimit = 3
    private static var cachedLabels: (key: String, values: [String])?

    private struct HourBucketID: Hashable, Identifiable {
        let dayID: String
        let hour: Int
        var id: String { "\(dayID)-\(hour)" }
    }

    private struct HourCellSpec {
        let day: CalendarDay
        let hour: Int
        let label: String
        let entries: [CalendarEntry]
        let minHeight: CGFloat
        let showNowLine: Bool
        let currentMinute: Int
    }

    private var gutterWidth: CGFloat { metrics.points(50) }
    private var hasFrequent: Bool { days.contains { !$0.frequentEntries.isEmpty } }

    var body: some View {
        let buckets = days.map { day in
            Dictionary(grouping: day.timedEntries) { calendar.component(.hour, from: $0.start) }
        }
        let hourLabels = Self.hourLabels(calendar: calendar)
        let scrollHour = preferredScrollHour(buckets: buckets)
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        let weekKey = days.first?.id ?? ""
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        // Keep all 24 rows eager inside the section so initial scrollTo is exact.
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                hourRow(
                                    hour: hour,
                                    label: hourLabels[hour],
                                    buckets: buckets,
                                    currentHour: currentHour,
                                    currentMinute: currentMinute
                                )
                                .id("calendarHour-\(hour)")
                                if hour < 23 {
                                    Divider().opacity(0.45)
                                }
                            }
                        }
                    } header: {
                        stickyHeader
                    }
                }
            }
            .accessibilityIdentifier("calendarWeekScroll")
            .onChange(of: weekKey, initial: true) { _, _ in
                proxy.scrollTo("calendarHour-\(scrollHour)", anchor: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendarWeekGrid")
    }

    private func preferredScrollHour(buckets: [[Int: [CalendarEntry]]]) -> Int {
        if let earliest = buckets.flatMap(\.keys).min() {
            return max(0, min(earliest - 1, 17))
        }
        if days.contains(where: \.isToday) {
            return max(0, min(calendar.component(.hour, from: now) - 2, 17))
        }
        return 8
    }

    private var stickyHeader: some View {
        VStack(spacing: 0) {
            dayHeaderRow
            Divider()
            if hasFrequent {
                frequentRow
                Divider()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: metrics.points(32))
            ForEach(days) { day in
                Divider()
                weekDayHeader(day)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.points(5))
                    .padding(.horizontal, metrics.points(2))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func weekDayHeader(_ day: CalendarDay) -> some View {
        let shortName = day.date.formatted(.dateTime.weekday(.abbreviated))
        let narrowName = day.date.formatted(.dateTime.weekday(.narrow))
        let badge = CalendarDayNumberBadge(
            number: "\(calendar.component(.day, from: day.date))",
            isToday: day.isToday,
            isMuted: false
        )
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: metrics.points(4)) {
                weekdayLabel(shortName, style: .caption, isToday: day.isToday)
                badge
            }
            VStack(spacing: metrics.points(2)) {
                weekdayLabel(narrowName, style: .caption2, isToday: day.isToday)
                badge
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendarWeekHeader-" + day.id)
    }

    private func weekdayLabel(_ text: String, style: InterfaceTextStyle, isToday: Bool) -> some View {
        Text(text)
            .interfaceFont(style)
            .fontWeight(isToday ? .semibold : .medium)
            .foregroundStyle(isToday ? Color.primary : Color.secondaryText)
            .lineLimit(1)
    }

    private var frequentRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Freq.")
                .interfaceFont(.caption2)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, metrics.points(6))
                .padding(.top, metrics.points(6))
                .help("High-frequency schedules")
            ForEach(days) { day in
                Divider()
                VStack(alignment: .leading, spacing: metrics.points(3)) {
                    ForEach(day.frequentEntries) { entry in
                        CalendarEntryChip(entry: entry, compact: true) { openEntry(entry) }
                    }
                }
                .padding(metrics.points(3))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(day.isToday ? Color.accentColor.opacity(0.035) : Color.clear)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hourRow(
        hour: Int, label: String, buckets: [[Int: [CalendarEntry]]],
        currentHour: Int, currentMinute: Int
    ) -> some View {
        let hasEntries = buckets.contains { !($0[hour]?.isEmpty ?? true) }
        let minHeight = metrics.points(hasEntries ? 48 : 26)
        return HStack(alignment: .top, spacing: 0) {
            Text(label)
                .interfaceFont(.caption2)
                .monospacedDigit()
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, metrics.points(6))
                .padding(.top, metrics.points(4))
            ForEach(days.indices, id: \.self) { index in
                let day = days[index]
                Divider()
                hourCell(HourCellSpec(
                    day: day,
                    hour: hour,
                    label: label,
                    entries: buckets[index][hour] ?? [],
                    minHeight: minHeight,
                    showNowLine: day.isToday && hour == currentHour,
                    currentMinute: currentMinute
                ))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hourCell(_ spec: HourCellSpec) -> some View {
        let ordered = CalendarEntryVisual.prioritized(spec.entries, limit: Self.cellLimit)
        let overflow = max(0, ordered.count - Self.cellLimit)
        return VStack(alignment: .leading, spacing: metrics.points(3)) {
            ForEach(ordered.prefix(Self.cellLimit)) { entry in
                CalendarEntryChip(entry: entry) { openEntry(entry) }
            }
            if overflow > 0 {
                overflowButton(spec: spec, overflow: overflow)
            }
        }
        .padding(metrics.points(3))
        .frame(maxWidth: .infinity, minHeight: spec.minHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(spec.day.isToday ? Color.accentColor.opacity(0.035) : Color.clear)
        .overlay {
            if spec.showNowLine {
                CurrentTimeLine(minute: spec.currentMinute)
            }
        }
    }

    private func overflowButton(spec: HourCellSpec, overflow: Int) -> some View {
        let bucketID = HourBucketID(dayID: spec.day.id, hour: spec.hour)
        let popoverBinding = Binding(
            get: { overflowSelection == bucketID },
            set: { if !$0 && overflowSelection == bucketID { overflowSelection = nil } }
        )
        return Button {
            overflowSelection = bucketID
        } label: {
            Text("+\(overflow) more")
                .interfaceFont(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.points(4))
                .padding(.vertical, metrics.points(1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendarWeekOverflow-\(bucketID.id)")
        .popover(isPresented: popoverBinding, arrowEdge: .bottom) {
            overflowPopover(day: spec.day, hourLabel: spec.label, entries: spec.entries)
        }
    }

    private func overflowPopover(day: CalendarDay, hourLabel: String, entries: [CalendarEntry]) -> some View {
        let title = day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let wideTime = entries.contains(where: \.isFrequent)
        return VStack(alignment: .leading, spacing: metrics.points(6)) {
            Text("\(title) \u{00B7} \(hourLabel)")
                .interfaceFont(.callout)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.points(6))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.points(2)) {
                    ForEach(entries) { entry in
                        CalendarAgendaRow(
                            entry: entry,
                            wideTimeColumn: wideTime,
                            idPrefix: "calendarPopoverEntry-"
                        ) {
                            overflowSelection = nil
                            openEntry(entry)
                        }
                    }
                }
            }
            .frame(maxHeight: metrics.points(240))
        }
        .padding(metrics.points(10))
        .frame(width: metrics.points(340))
    }

    private static func hourLabels(calendar: Calendar) -> [String] {
        let key = "\(calendar.locale?.identifier ?? "")|\(calendar.timeZone.identifier)"
        if let cached = cachedLabels, cached.key == key {
            return cached.values
        }
        var components = DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let midnight = calendar.date(from: components) ?? Date()
        let values = (0..<24).map { hour in
            midnight.addingTimeInterval(Double(hour * 3600)).formatted(.dateTime.hour())
        }
        cachedLabels = (key, values)
        return values
    }
}

private struct CurrentTimeLine: View {
    let minute: Int

    var body: some View {
        GeometryReader { geo in
            let y = geo.size.height * CGFloat(max(0, min(minute, 59))) / 60.0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.errorText)
                    .frame(height: 1.5)
                Circle()
                    .fill(Color.errorText)
                    .frame(width: 6, height: 6)
                    .offset(x: -3)
            }
            .position(x: geo.size.width / 2, y: y)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

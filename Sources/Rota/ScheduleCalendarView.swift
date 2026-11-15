import AppKit
import RotaCore
import SwiftUI

/// Persisted display preferences and current date cursor for the Calendar view.
@MainActor
@Observable
final class CalendarPresentationState {
    private let defaults: UserDefaults

    var mode: CalendarViewMode {
        didSet { defaults.set(mode.rawValue, forKey: "calendarMode") }
    }

    var showPaused: Bool {
        didSet { defaults.set(showPaused, forKey: "calendarShowPaused") }
    }

    var anchor: Date
    var selectedDay: Date

    init(defaults: UserDefaults = .standard, now: Date = .now, calendar: Calendar = .current) {
        self.defaults = defaults
        mode = defaults.string(forKey: "calendarMode").flatMap(CalendarViewMode.init(rawValue:)) ?? .week
        showPaused = defaults.object(forKey: "calendarShowPaused") as? Bool ?? false
        anchor = now
        selectedDay = calendar.startOfDay(for: now)
    }

    func step(_ offset: Int, now: Date = .now, calendar: Calendar = .current) {
        anchor = ScheduleCalendar.stepped(anchor, mode: mode, by: offset, calendar: calendar)
        if mode == .month {
            let month = ScheduleCalendar.monthGridInterval(containing: anchor, calendar: calendar).month
            let today = calendar.startOfDay(for: now)
            selectedDay = (today >= month.start && today < month.end) ? today : month.start
        } else {
            selectedDay = calendar.startOfDay(for: anchor)
        }
    }

    func goToToday(now: Date = .now, calendar: Calendar = .current) {
        anchor = now
        selectedDay = calendar.startOfDay(for: now)
    }
}

extension AppModel {
    func showCalendar() {
        guard !scheduler.routines.isEmpty else { return }
        closeSettings()
        showMainWindow(selecting: .calendar)
    }

    func openCalendarEntry(_ entry: CalendarEntry) {
        if let record = entry.record, !record.isSkip {
            selection = .session(record.id)
        } else {
            selection = .routine(entry.routineID)
        }
    }
}

/// Global schedule calendar across all routines: Week time grid, Month grid and Agenda list.
struct ScheduleCalendarView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(now: timeline.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduleCalendarView")
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        @Bindable var state = model.calendar
        let calendar = model.scheduler.calendar
        let routines = model.scheduler.routines
        let slice = makeSlice(now: now, routines: routines, calendar: calendar)
        let counts = summaryCounts(days: slice.days, routines: routines)
        VStack(spacing: 0) {
            CalendarHeaderBar(
                title: periodTitle(mode: state.mode, interval: slice.visible, calendar: calendar),
                subtitle: counts.fullText(showPaused: state.showPaused),
                compactSubtitle: counts.compactText(showPaused: state.showPaused),
                pausedCount: counts.paused,
                mode: $state.mode,
                showPaused: $state.showPaused,
                onPrevious: { state.step(-1, now: now, calendar: calendar) },
                onToday: { state.goToToday(now: now, calendar: calendar) },
                onNext: { state.step(1, now: now, calendar: calendar) }
            )
            .padding(.horizontal, metrics.points(16))
            .padding(.vertical, metrics.points(10))
            Divider()
            switch state.mode {
            case .week:
                CalendarWeekView(days: slice.days, now: now, calendar: calendar) { model.openCalendarEntry($0) }
            case .month:
                CalendarMonthView(
                    days: slice.days,
                    selectedDay: $state.selectedDay,
                    calendar: calendar,
                    openEntry: { model.openCalendarEntry($0) }
                )
            case .agenda:
                CalendarAgendaView(
                    days: slice.days,
                    allPausedHidden: counts.isAllPausedHidden(showPaused: state.showPaused),
                    enablePaused: { state.showPaused = true },
                    openEntry: { model.openCalendarEntry($0) }
                )
            }
        }
    }

    private struct Slice {
        let visible: DateInterval
        let days: [CalendarDay]
    }

    private struct SummaryCounts {
        let enabled: Int
        let paused: Int
        let upcoming: Int
        let recorded: Int

        func isAllPausedHidden(showPaused: Bool) -> Bool {
            !showPaused && enabled == 0 && paused > 0
        }

        func fullText(showPaused: Bool) -> String {
            var parts: [String] = []
            if isAllPausedHidden(showPaused: showPaused) {
                parts.append("All routines paused")
            } else {
                parts.append("\(enabled) active")
                if showPaused && paused > 0 { parts.append("\(paused) paused") }
            }
            if upcoming > 0 { parts.append("\(upcoming) upcoming") }
            if recorded > 0 { parts.append("\(recorded) recorded") }
            return parts.joined(separator: " \u{00B7} ")
        }

        func compactText(showPaused: Bool) -> String {
            if isAllPausedHidden(showPaused: showPaused) { return "All paused" }
            var parts: [String] = []
            if upcoming > 0 { parts.append("\(upcoming) upcoming") }
            if recorded > 0 { parts.append("\(recorded) recorded") }
            return parts.isEmpty ? "\(enabled) active" : parts.joined(separator: " \u{00B7} ")
        }
    }

    private func makeSlice(now: Date, routines: [Routine], calendar: Calendar) -> Slice {
        _ = model.scheduler.historyVersion
        let state = model.calendar
        let window = ScheduleCalendar.window(for: state.mode, anchor: state.anchor, calendar: calendar)
        let windowRecords = routines.flatMap { routine in
            model.scheduler.records(for: routine.id).filter {
                $0.startedAt >= window.query.start && $0.startedAt < window.query.end
            }
        }
        let query = ScheduleCalendar.Query(
            interval: window.query, currentMonth: window.currentMonth, now: now,
            includePaused: state.showPaused, calendar: calendar
        )
        return Slice(
            visible: window.visible,
            days: ScheduleCalendar.days(query: query, routines: routines, records: windowRecords)
        )
    }

    private func periodTitle(mode: CalendarViewMode, interval: DateInterval, calendar: Calendar) -> String {
        switch mode {
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .week, .agenda:
            let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
            let startNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: interval.start)
                ?? interval.start
            let endNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: lastDay)
                ?? max(startNoon, lastDay)
            return (min(startNoon, endNoon)..<max(startNoon, endNoon))
                .formatted(.interval.month(.abbreviated).day().year())
        }
    }

    private func summaryCounts(days: [CalendarDay], routines: [Routine]) -> SummaryCounts {
        var enabled = 0
        var paused = 0
        for routine in routines where !routine.isScheduleComplete {
            if routine.enabled { enabled += 1 } else { paused += 1 }
        }
        var upcoming = 0
        var recorded = 0
        for day in days where day.isCurrentMonth {
            upcoming += day.scheduledCount
            recorded += day.recordedCount
        }
        return SummaryCounts(enabled: enabled, paused: paused, upcoming: upcoming, recorded: recorded)
    }
}

private struct CalendarHeaderBar: View {
    @Environment(\.interfaceScale) private var metrics
    let title: String
    let subtitle: String
    let compactSubtitle: String
    let pausedCount: Int
    @Binding var mode: CalendarViewMode
    @Binding var showPaused: Bool
    let onPrevious: () -> Void
    let onToday: () -> Void
    let onNext: () -> Void

    private var barHeight: CGFloat { metrics.points(28) }
    private var controlFont: Font { Font(InterfaceTypography.font(size: metrics.points(12.5), semibold: false)) }
    private var activeControlFont: Font { Font(InterfaceTypography.font(size: metrics.points(12.5), semibold: true)) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalBar(text: subtitle, spacing: 12, minSpacer: 8, iconOnlyPaused: false)
            horizontalBar(text: compactSubtitle, spacing: 10, minSpacer: 6, iconOnlyPaused: false)
            horizontalBar(text: compactSubtitle, spacing: 10, minSpacer: 6, iconOnlyPaused: true)
            VStack(alignment: .leading, spacing: metrics.points(8)) {
                summaryBlock(text: subtitle)
                ViewThatFits(in: .horizontal) {
                    controlsRow(iconOnlyPaused: false).fixedSize()
                    controlsRow(iconOnlyPaused: true).fixedSize()
                    VStack(alignment: .leading, spacing: metrics.points(6)) {
                        modeSwitch.fixedSize()
                        HStack(spacing: metrics.points(8)) {
                            pausedToggle(iconOnly: false)
                            navigationGroup
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func horizontalBar(
        text: String, spacing: CGFloat, minSpacer: CGFloat, iconOnlyPaused: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: metrics.points(spacing)) {
            summaryBlock(text: text)
            Spacer(minLength: metrics.points(minSpacer))
            controlsRow(iconOnlyPaused: iconOnlyPaused).fixedSize()
        }
    }

    private func summaryBlock(text: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.points(2)) {
            Text(title)
                .interfaceFont(.title2)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("calendarPeriodTitle")
            Text(text)
                .interfaceFont(.caption)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
                .accessibilityIdentifier("calendarSubtitle")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func controlsRow(iconOnlyPaused: Bool) -> some View {
        HStack(alignment: .center, spacing: metrics.points(8)) {
            modeSwitch
            pausedToggle(iconOnly: iconOnlyPaused)
            navigationGroup
        }
    }

    private var modeSwitch: some View {
        let regular = controlFont
        let semibold = activeControlFont
        return HStack(spacing: metrics.points(2)) {
            ForEach(CalendarViewMode.allCases) { item in
                let active = mode == item
                Button {
                    mode = item
                } label: {
                    Text(item.title)
                        .font(active ? semibold : regular)
                        .foregroundStyle(active ? Color.onControlAccent : Color.primary)
                        .padding(.horizontal, metrics.points(10))
                        .frame(height: barHeight - metrics.points(4))
                        .background {
                            if active { Capsule().fill(Color.accentColor) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
                .accessibilityIdentifier("calendarMode-" + item.rawValue)
            }
        }
        .padding(.horizontal, metrics.points(2))
        .frame(height: barHeight)
        .modifier(ControlSurface(shape: Capsule()))
    }

    private func pausedToggle(iconOnly: Bool) -> some View {
        let helpText: String
        if showPaused {
            helpText = "Hide paused routines from the calendar"
        } else if pausedCount > 0 {
            helpText = "Show \(pausedCount) paused \(pausedCount == 1 ? "routine" : "routines") on the calendar"
        } else {
            helpText = "Show paused routines on the calendar"
        }
        let symbol = showPaused ? "pause.circle.fill" : "pause.circle"
        return Button {
            showPaused.toggle()
        } label: {
            Group {
                if iconOnly {
                    Image(systemName: symbol)
                        .interfaceSystemFont(size: 13, weight: .medium)
                        .frame(width: barHeight)
                } else {
                    HStack(spacing: metrics.points(4)) {
                        Image(systemName: symbol)
                            .interfaceSystemFont(size: 12, weight: .medium)
                        Text("Paused")
                            .font(showPaused ? activeControlFont : controlFont)
                    }
                    .padding(.horizontal, metrics.points(9))
                }
            }
            .frame(height: barHeight)
            .foregroundStyle(showPaused ? Color.onControlAccent : Color.primary)
            .background {
                if showPaused { Capsule().fill(Color.accentColor) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ControlSurface(shape: Capsule()))
        .help(helpText)
        .accessibilityLabel("Show Paused Routines")
        .accessibilityValue(showPaused ? "On" : "Off")
        .accessibilityIdentifier("calendarTogglePaused")
    }

    private var navigationGroup: some View {
        HStack(spacing: 0) {
            stepButton(symbol: "chevron.left", help: "Previous period",
                       label: "Previous Period", id: "calendarPrevious", action: onPrevious)
            Divider().frame(height: metrics.points(14))
            Button(action: onToday) {
                Text("Today")
                    .font(controlFont)
                    .padding(.horizontal, metrics.points(9))
                    .frame(height: barHeight)
                    .contentShape(Rectangle())
            }
            .help("Jump to today")
            .accessibilityIdentifier("calendarToday")
            Divider().frame(height: metrics.points(14))
            stepButton(symbol: "chevron.right", help: "Next period",
                       label: "Next Period", id: "calendarNext", action: onNext)
        }
        .buttonStyle(.plain)
        .frame(height: barHeight)
        .modifier(ControlSurface(shape: Capsule()))
    }

    private func stepButton(
        symbol: String, help: String, label: String, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .interfaceSystemFont(size: 11, weight: .semibold)
                .frame(width: barHeight, height: barHeight)
                .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// Chronological day-by-day schedule list for the Agenda mode.
struct CalendarAgendaView: View {
    @Environment(\.interfaceScale) private var metrics
    let days: [CalendarDay]
    let allPausedHidden: Bool
    let enablePaused: () -> Void
    let openEntry: (CalendarEntry) -> Void

    var body: some View {
        let activeDays = days.filter { !$0.entries.isEmpty }
        if activeDays.isEmpty {
            emptyState
        } else {
            List {
                ForEach(activeDays) { day in
                    let wideTime = day.entries.contains(where: \.isFrequent)
                    Section {
                        ForEach(day.entries) { entry in
                            CalendarAgendaRow(entry: entry, wideTimeColumn: wideTime) { openEntry(entry) }
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(CalendarEntryVisual.dayHeading(day))
                                .fontWeight(.semibold)
                                .foregroundStyle(day.isToday ? Color.primary : Color.secondaryText)
                            Spacer(minLength: metrics.points(8))
                            Text(CalendarEntryVisual.dayCountSummary(day))
                                .foregroundStyle(Color.secondaryText)
                        }
                        .interfaceFont(.caption)
                        .textCase(nil)
                    }
                }
            }
            .accessibilityIdentifier("calendarAgendaList")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No runs or scheduled slots", systemImage: "calendar")
                .interfaceFont(.title2)
        } description: {
            Text(allPausedHidden
                 ? "All routines are currently paused. Show paused routines to preview when they would run."
                 : "Nothing is recorded or scheduled in this two-week window.")
                .interfaceFont(.body)
                .foregroundStyle(Color.secondaryText)
        } actions: {
            if allPausedHidden {
                Button(interfaceTitle: "Show Paused Routines", action: enablePaused)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("calendarEmptyShowPaused")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

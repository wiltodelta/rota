import RotaCore
import SwiftUI

/// The Schedule's seven days and whether paused routines show.
@MainActor
@Observable
final class SchedulePresentationState {
    static let days = 7
    private let defaults: UserDefaults

    var showPaused: Bool {
        didSet { defaults.set(showPaused, forKey: "calendarShowPaused") }
    }

    /// The first of the days shown: today until the user steps.
    var start: Date
    /// The day the strip last chose; the list scrolls to it.
    var selectedDay: Date?

    init(defaults: UserDefaults = .standard, now: Date = .now, calendar: Calendar = .current) {
        self.defaults = defaults
        showPaused = defaults.object(forKey: "calendarShowPaused") as? Bool ?? false
        start = calendar.startOfDay(for: now)
    }

    func step(_ weeks: Int, calendar: Calendar = .current) {
        start = calendar.date(byAdding: .day, value: Self.days * weeks, to: start) ?? start
        selectedDay = nil
    }

    func goToToday(now: Date = .now, calendar: Calendar = .current) {
        start = calendar.startOfDay(for: now)
        selectedDay = start
    }
}

extension AppModel {
    var showsSchedule: Bool { selection == .calendar && settingsPane == nil }

    func toggleSchedule() {
        if showsSchedule { closeSchedule() } else { showSchedule() }
    }

    /// Replaces the detail with the Schedule; Escape or the toolbar button returns.
    func showSchedule() {
        guard !scheduler.routines.isEmpty else { return }
        closeSettings()
        if selection != .calendar { selectionBeforeSchedule = selection }
        showMainWindow(selecting: .calendar)
    }

    func closeSchedule() {
        guard selection == .calendar else { return }
        selection = selectionBeforeSchedule
        selectionBeforeSchedule = nil
    }

    var allRoutinesPaused: Bool {
        !scheduler.routines.isEmpty && scheduler.routines.allSatisfy { !$0.enabled }
    }

    func openScheduleEntry(_ entry: CalendarEntry) {
        selectionBeforeSchedule = nil
        selection = .routine(entry.routineID)
    }
}

/// What runs next across routines: a strip of seven days, then each day's slots.
/// History lives in Sessions, so the past shows only what Sessions does not: skipped slots.
struct ScheduleView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(now: timeline.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Escape leaves the Schedule wherever focus is, as Back does in Settings.
            Button("Close Schedule") { model.closeSchedule() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduleView")
    }

    private func content(now: Date) -> some View {
        let calendar = model.scheduler.calendar
        let days = Self.days(model: model, now: now, calendar: calendar)
        return VStack(spacing: 0) {
            ScheduleHeader(days: days, now: now)
                .padding(.horizontal, metrics.points(16))
                .padding(.top, metrics.points(10))
            ScheduleWeekStrip(days: days)
                .padding(.horizontal, metrics.points(12))
                .padding(.vertical, metrics.points(6))
            Divider()
            ScheduleDayList(days: days)
        }
    }

    /// Upcoming slots, and skipped slots in the past; finished runs stay in Sessions.
    static func days(model: AppModel, now: Date, calendar: Calendar) -> [CalendarDay] {
        _ = model.scheduler.historyVersion
        let state = model.schedule
        let interval = ScheduleCalendar.agendaInterval(
            startingAt: state.start, days: SchedulePresentationState.days, calendar: calendar)
        let routines = model.scheduler.routines
        let skips = routines.flatMap { routine in
            model.scheduler.records(for: routine.id).filter {
                $0.isSkip && $0.startedAt >= interval.start && $0.startedAt < interval.end
            }
        }
        let query = ScheduleCalendar.Query(interval: interval, now: now, includePaused: state.showPaused,
                                           calendar: calendar)
        return ScheduleCalendar.days(query: query, routines: routines, records: skips)
    }
}

private struct ScheduleHeader: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let days: [CalendarDay]
    let now: Date

    var body: some View {
        @Bindable var state = model.schedule
        let calendar = model.scheduler.calendar
        HStack(alignment: .center, spacing: metrics.points(10)) {
            VStack(alignment: .leading, spacing: metrics.points(2)) {
                Text(rangeTitle)
                    .interfaceFont(.title2).fontWeight(.semibold)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityIdentifier("schedulePeriodTitle")
                Text(nextRun)
                    .interfaceFont(.caption).foregroundStyle(Color.secondaryText)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("scheduleNextRun")
            }
            Spacer(minLength: metrics.points(8))
            Menu {
                Toggle("Show Paused Routines", isOn: $state.showPaused)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .interfaceSystemFont(size: 13, weight: .medium)
                    .frame(width: metrics.points(28), height: metrics.points(28))
                    .modifier(ControlSurface(shape: Circle(),
                                             tint: state.showPaused ? Color.accentColor.opacity(0.2) : nil))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(state.showPaused ? "Showing paused routines" : "Show paused routines")
            .accessibilityLabel("Schedule Options")
            .accessibilityIdentifier("scheduleOptions")
            ScheduleNavigation(
                previous: { state.step(-1, calendar: calendar) },
                today: { state.goToToday(now: now, calendar: calendar) },
                next: { state.step(1, calendar: calendar) })
        }
    }

    private var rangeTitle: String {
        guard let first = days.first?.date, let last = days.last?.date else { return "Schedule" }
        let noon = { (date: Date) in
            model.scheduler.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        }
        return (noon(first)..<noon(last)).formatted(.interval.month(.abbreviated).day().year())
    }

    /// The first upcoming slot, or why there is none.
    private var nextRun: String {
        let next = days.lazy.flatMap(\.entries).first { $0.record == nil && !$0.isPaused && $0.start >= now }
        if let next {
            let when = next.start.timeIntervalSince(now) < 24 * 3600
                ? next.start.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
                : next.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "Next: \(next.routineName) \(when)"
        }
        return model.allRoutinesPaused ? "All routines are paused" : "Nothing scheduled in these seven days"
    }
}

private struct ScheduleNavigation: View {
    @Environment(\.interfaceScale) private var metrics
    let previous: () -> Void
    let today: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            step("chevron.left", label: "Previous Week", id: "schedulePrevious", action: previous)
            Divider().frame(height: metrics.points(14))
            Button(action: today) {
                Text("Today").interfaceFont(.callout)
                    .padding(.horizontal, metrics.points(9))
                    .frame(height: metrics.points(28))
                    .contentShape(Rectangle())
            }
            .help("Start at today")
            .accessibilityIdentifier("scheduleToday")
            Divider().frame(height: metrics.points(14))
            step("chevron.right", label: "Next Week", id: "scheduleNext", action: next)
        }
        .buttonStyle(.plain)
        .frame(height: metrics.points(28))
        .modifier(ControlSurface(shape: Capsule()))
        .fixedSize()
    }

    private func step(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .interfaceSystemFont(size: 11, weight: .semibold)
                .frame(width: metrics.points(28), height: metrics.points(28))
                .contentShape(Rectangle())
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// Seven day cells marking which routines run each day; choosing one scrolls the list to it.
private struct ScheduleWeekStrip: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let days: [CalendarDay]

    var body: some View {
        HStack(spacing: metrics.points(4)) {
            ForEach(days) { day in
                cell(day)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduleWeekStrip")
    }

    private func cell(_ day: CalendarDay) -> some View {
        let selected = model.schedule.selectedDay.map { model.scheduler.calendar.isDate($0, inSameDayAs: day.date) }
            ?? false
        let summary = CalendarEntryVisual.dayCountSummary(day)
        return Button { model.schedule.selectedDay = day.date } label: {
            VStack(spacing: metrics.points(3)) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                    .interfaceFont(.caption).foregroundStyle(Color.secondaryText)
                Text(day.date.formatted(.dateTime.day()))
                    .interfaceFont(.body).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(day.isToday ? Color.onControlAccent : Color.primary)
                    .frame(minWidth: metrics.points(26), minHeight: metrics.points(26))
                    .background { if day.isToday { Circle().fill(Color.accentColor) } }
                ScheduleDayDots(day: day)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, metrics.points(4))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: metrics.points(8)).strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(summary.isEmpty ? "Nothing scheduled" : summary)
        .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
                            + ", " + (summary.isEmpty ? "nothing scheduled" : summary))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("scheduleDay-" + day.id)
    }
}

/// Each day with slots, under its heading; frequent schedules collapse into one row.
private struct ScheduleDayList: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let days: [CalendarDay]

    var body: some View {
        let filled = days.filter { !$0.entries.isEmpty }
        if filled.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(filled) { day in
                        Section {
                            ForEach(day.entries) { entry in
                                CalendarAgendaRow(entry: entry) { model.openScheduleEntry(entry) }
                            }
                        } header: {
                            heading(day)
                        }
                        .id(day.id)
                    }
                }
                .accessibilityIdentifier("scheduleList")
                .onChange(of: model.schedule.selectedDay) { _, day in
                    guard let day else { return }
                    let calendar = model.scheduler.calendar
                    // An empty day has no section: go to the next day that has one.
                    let target = filled.first { calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: day) }
                    if let target { withAnimation { proxy.scrollTo(target.id, anchor: .top) } }
                }
            }
        }
    }

    private func heading(_ day: CalendarDay) -> some View {
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

    private var emptyState: some View {
        let allPaused = model.allRoutinesPaused
        return ContentUnavailableView {
            Label("Nothing scheduled", systemImage: "calendar")
                .interfaceFont(.title2)
        } description: {
            Text(allPaused && !model.schedule.showPaused
                 ? "All routines are paused. Show paused routines to see when they would run."
                 : "No routine runs in these seven days.")
                .interfaceFont(.body)
                .foregroundStyle(Color.secondaryText)
        } actions: {
            if allPaused && !model.schedule.showPaused {
                Button(interfaceTitle: "Show Paused Routines") { model.schedule.showPaused = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scheduleShowPaused")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A dot for each routine that runs that day, however often, and an orange one for a skipped slot.
/// A count would read the same every day once one routine runs every few minutes.
private struct ScheduleDayDots: View {
    static let limit = 4
    @Environment(\.interfaceScale) private var metrics
    let day: CalendarDay

    var body: some View {
        let routines = Set(day.entries.filter { $0.record == nil }.map(\.routineID)).count
        HStack(spacing: metrics.points(3)) {
            ForEach(0..<min(routines, Self.limit), id: \.self) { _ in dot(Color.accentColor) }
            if routines > Self.limit {
                Text("+").interfaceFont(.caption2).foregroundStyle(Color.secondaryText)
            }
            if day.recordedCount > 0 { dot(Color.orange) }
            if routines == 0, day.recordedCount == 0 { dot(Color.secondaryText.opacity(0.25)) }
        }
        .frame(height: metrics.points(8))
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: metrics.points(5), height: metrics.points(5))
    }
}

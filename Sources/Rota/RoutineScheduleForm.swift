import RotaCore
import SwiftUI

/// A date first, with repetition and its ending condition revealed when needed.
struct RoutineScheduleForm: View {
    @Environment(\.interfaceScale) private var metrics
    @Binding var draft: Routine
    @State private var pattern: Repetition

    init(draft: Binding<Routine>) {
        _draft = draft
        _pattern = State(initialValue: Repetition.match(draft.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(8)) {
            LabeledContent("When") {
                DatePicker("When", selection: date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("routineDate")
            }
            .labeledContentStyle(InterfaceFormRowStyle())
            InterfacePicker(title: "Repeat", selection: $pattern,
                            choices: Repetition.allCases.map { .item($0.rawValue, $0) },
                            identifier: "routineRepeat")
                .onChange(of: pattern) { _, value in
                    draft.repeats = value != .once
                    draft.scheduledAt = date.wrappedValue
                    if value == .once { draft.runLimit = nil }
                    updateCron()
                    resetProgress()
                }
            if pattern == .custom { cronField }
            if draft.repeats {
                InterfacePicker(title: "Ends", selection: Binding(
                    get: { draft.runLimit != nil },
                    set: { draft.runLimit = $0 ? 2 : nil; resetProgress() }
                ), choices: [.item("Never", false), .item("After a Number of Runs", true)],
                identifier: "routineEnds")
                if let limit = draft.runLimit {
                    LabeledContent("Scheduled runs in total") {
                        TextField("Scheduled runs in total", value: Binding(
                            get: { limit }, set: { draft.runLimit = $0; resetProgress() }
                        ), format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: metrics.points(72))
                            .accessibilityLabel("Scheduled runs in total")
                            .accessibilityIdentifier("routineRunLimit")
                    }
                    .labeledContentStyle(InterfaceFormRowStyle())
                    Text("Manual runs and skipped slots do not count.")
                        .interfaceFont(.caption).foregroundStyle(Color.secondaryText)
                }
            }
            Text(preview).interfaceFont(.caption).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("routineSchedulePreview")
        }
        .accessibilityElement(children: .contain)
    }

    private var date: Binding<Date> {
        Binding(get: {
            draft.scheduledAt ?? draft.nextScheduledFire(after: .now) ?? Self.suggestedDate()
        }, set: { value in
            draft.scheduledAt = value
            updateCron()
            resetProgress()
        })
    }

    static func suggestedDate() -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                                          from: Date.now.addingTimeInterval(3600))) ?? .now
    }

    private var cronField: some View {
        LabeledContent("Cron schedule") {
            HStack(spacing: metrics.points(8)) {
                TextField("Cron schedule", text: $draft.schedule, prompt: Text("minute hour day month weekday"))
                    .labelsHidden().interfaceFont(.body).monospaced()
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("routineSchedule")
                    .onChange(of: draft.schedule) { resetProgress() }
                Menu {
                    ForEach(ScheduleText.presets, id: \.self) { cron in
                        Button(ScheduleText.describe(cron) ?? cron) { draft.schedule = cron }
                    }
                } label: { Image(systemName: "clock") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Common schedules").accessibilityLabel("Common schedules")
                .accessibilityIdentifier("schedulePresets")
            }
        }
        .labeledContentStyle(InterfaceFormRowStyle())
    }

    private var preview: String {
        if draft.isScheduleComplete {
            return "Schedule complete. Change its date, repetition or run limit to start again."
        }
        if let next = draft.nextScheduledFire(after: .now) {
            return "Next: " + next.formatted(date: .abbreviated, time: .shortened)
                + ". " + TimeZone.current.identifier
        }
        return draft.repeats ? "Choose a valid cron schedule with an upcoming run." : "Choose a date and time."
    }

    private func resetProgress() {
        draft.scheduledRunCount = 0
        draft.scheduleCompletedAt = nil
    }

    private func updateCron() {
        let parts = Calendar.current.dateComponents([.minute, .hour, .day, .weekday], from: date.wrappedValue)
        let time = "\(parts.minute ?? 0) \(parts.hour ?? 9)"
        switch pattern {
        case .daily: draft.schedule = time + " * * *"
        case .weekdays: draft.schedule = time + " * * 1-5"
        case .weekly: draft.schedule = time + " * * \((parts.weekday ?? 2) - 1)"
        case .monthly: draft.schedule = time + " \(parts.day ?? 1) * *"
        case .once, .custom: break
        }
    }
}

private enum Repetition: String, CaseIterable {
    case once = "Does Not Repeat"
    case daily = "Daily"
    case weekdays = "Weekdays"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case custom = "Custom"

    static func match(_ routine: Routine) -> Repetition {
        guard routine.repeats else { return .once }
        let fields = routine.schedule.split(separator: " ").map(String.init)
        guard fields.count == 5, Int(fields[0]) != nil, Int(fields[1]) != nil, fields[3] == "*" else { return .custom }
        if fields[2] == "*" {
            if fields[4] == "*" { return .daily }
            if fields[4] == "1-5" { return .weekdays }
            if Int(fields[4]) != nil { return .weekly }
        } else if Int(fields[2]) != nil, fields[4] == "*" { return .monthly }
        return .custom
    }
}

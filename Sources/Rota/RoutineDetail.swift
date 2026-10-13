import RotaCore
import SwiftUI

/// A routine: when it runs next, the switch that pauses it, Run Now, and its
/// sessions. Its settings change rarely, so they live in a sheet.
struct RoutineDetail: View {
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(AppModel.self) private var model
    let routine: Routine

    private var records: [RunRecord] {
        _ = model.scheduler.historyVersion
        return model.scheduler.history.records(for: routine.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, metrics(20))
                .padding(.vertical, metrics(14))
            Divider()
            List(records) { record in
                Button {
                    model.selection = .session(record.id)
                } label: {
                    HStack(spacing: metrics(8)) {
                        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .fontWeight(record.isUnread ? .semibold : .regular)
                        Spacer(minLength: metrics(8))
                        if record.attention != nil {
                            Image(systemName: "exclamationmark.bubble.fill")
                                .foregroundStyle(.orange)
                                .help("Needs your reply")
                                .accessibilityLabel("Needs your reply")
                        }
                        Text(record.outcome.title)
                            .foregroundStyle(record.outcome.isFailure && !record.isSkip
                                ? Color.errorText : Color.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if records.isEmpty { Text("No sessions yet").foregroundStyle(Color.secondaryText) }
            }
        }
        .frame(minWidth: min(520, metrics(520)), maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(routine.name)
        .sheet(isPresented: Binding(
            get: { model.editingRoutineID == routine.id },
            set: { if !$0 { model.editingRoutineID = nil } }
        )) { EditRoutineSheet(routine: routine).appZoom() }
        .onAppear {
            // Development hook: open the editor for a capture script.
            if ProcessInfo.processInfo.environment["ROTA_OPEN_EDIT"] != nil { model.editingRoutineID = routine.id }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: metrics(12)) {
            VStack(alignment: .leading, spacing: metrics(3)) {
                Text(ScheduleText.describe(routine.schedule) ?? routine.schedule).scaledFont(.callout)
                // Only the folder gives way when the line is short of room.
                HStack(spacing: 0) {
                    Text("\(state) \u{00B7} \(harness) \u{00B7} ").layoutPriority(1)
                    Text(routine.workingDirectory).truncationMode(.middle)
                }
                .scaledFont(.caption)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
            }
            Spacer(minLength: metrics(12))
            Toggle("On", isOn: Binding(
                get: { routine.enabled },
                set: { model.scheduler.setEnabled($0, for: routine.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(routine.enabled ? "Runs on schedule; turn off to pause" : "Paused; turn on to run on schedule")
            .accessibilityIdentifier("routineEnabled")
            if model.scheduler.active[routine.id] != nil {
                Button("Stop", systemImage: "stop.fill") { model.scheduler.stop(routine.id) }
                    .accessibilityIdentifier("stopRoutine")
            } else {
                Button("Run Now", systemImage: "play.fill") {
                    model.scheduler.run(routine, trigger: .manual)
                    model.selection = model.latest(of: routine.id)
                }
                .accessibilityIdentifier("runNow")
            }
            Button("Edit\u{2026}", systemImage: "slider.horizontal.3") { model.editingRoutineID = routine.id }
                .help("Edit the routine's settings (Command-E)")
                .accessibilityIdentifier("editRoutine")
        }
    }

    /// "Codex gpt-6-sol high": where and on what it runs.
    private var harness: String {
        ([routine.harness.title] + [routine.model, routine.effort].compactMap { $0 }).joined(separator: " ")
    }

    /// "Next run Mon, Oct 12, 9:00 AM", or why it will not run.
    private var state: String {
        guard routine.enabled else { return "Paused" }
        guard let next = routine.nextFire else { return "No upcoming run" }
        return "Next run \(NextRunFormat.string(next))"
    }
}

/// The routine's settings, edited as a draft and saved together.
struct EditRoutineSheet: View {
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routine: Routine
    @State private var draft: Routine
    @State private var confirmingDelete = false

    init(routine: Routine) {
        self.routine = routine
        _draft = State(initialValue: routine)
    }

    var body: some View {
        let problem = draft.problem(checkingID: false)
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(text: "Edit Routine")
            RoutineForm(draft: $draft)
            HStack(spacing: metrics(8)) {
                Button("Delete Routine\u{2026}", role: .destructive) { confirmingDelete = true }
                Spacer(minLength: metrics(12))
                if let problem {
                    Text(problem)
                        .scaledFont(.callout)
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(2)
                        .accessibilityIdentifier("sheetProblem")
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.scheduler.save(draft)
                    dismiss()
                }
                .accessibilityIdentifier("saveRoutine")
                .buttonStyle(InterfaceButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(draft == routine || problem != nil)
            }
            .padding(metrics(16))
        }
        // Fits the window at its minimum height; the form scrolls inside.
        .frame(width: metrics.sheetWidth(600))
        .frame(minHeight: metrics.sheetHeight(360),
               idealHeight: metrics.sheetHeight(500))
        .confirmationDialog("Delete \(routine.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                dismiss()
                model.selection = nil
                model.scheduler.delete(routine.id)
            }
        } message: {
            Text("Its sessions and logs are deleted too. The project skill is not touched.")
        }
    }
}

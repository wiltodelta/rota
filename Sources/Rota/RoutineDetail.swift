import RotaCore
import SwiftUI

/// A routine: when it runs next, the switch that pauses it, Run Now, and its
/// sessions. Its settings change rarely, so they live in a sheet.
struct RoutineDetail: View {
    @Environment(AppModel.self) private var model
    let routine: Routine

    private var records: [RunRecord] {
        _ = model.scheduler.historyVersion
        return model.scheduler.history.records(for: routine.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            HarnessWarnings(routine: routine)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            Divider()
            List(records) { record in
                Button {
                    model.selection = .session(record.id)
                } label: {
                    HStack {
                        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(record.outcome.title)
                            .foregroundStyle(record.outcome.isFailure && !record.isSkip ? .red : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if records.isEmpty { Text("No sessions yet").foregroundStyle(.secondary) }
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(routine.name)
        .sheet(isPresented: Binding(
            get: { model.editingRoutineID == routine.id },
            set: { if !$0 { model.editingRoutineID = nil } }
        )) { EditRoutineSheet(routine: routine) }
        .onAppear {
            // Development hook: open the editor for a capture script.
            if ProcessInfo.processInfo.environment["ROTA_OPEN_EDIT"] != nil { model.editingRoutineID = routine.id }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).font(.callout)
                Text(routine.workingDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
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

    /// "Codex gpt-6-sol high, next run Mon, Oct 12, 10:15 AM", or why it will not run.
    private var summary: String {
        let harness = ([routine.harness.title] + [routine.model, routine.effort].compactMap { $0 })
            .joined(separator: " ")
        guard routine.enabled else { return "\(harness), paused" }
        guard let next = routine.nextFire else { return "\(harness), no upcoming run" }
        return "\(harness), next run \(NextRunFormat.string(next))"
    }
}

/// The routine's settings, edited as a draft and saved together.
struct EditRoutineSheet: View {
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
        VStack(spacing: 0) {
            RoutineForm(draft: $draft)
            HStack {
                Button("Delete Routine\u{2026}", role: .destructive) { confirmingDelete = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.scheduler.save(draft)
                    dismiss()
                }
                .accessibilityIdentifier("saveRoutine")
                .keyboardShortcut(.defaultAction)
                .disabled(draft == routine || (try? CronSchedule(draft.schedule)) == nil)
            }
            .padding(16)
        }
        // Fits the window at its minimum height; the form scrolls inside.
        .frame(width: 600)
        .frame(minHeight: 360, idealHeight: 500)
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

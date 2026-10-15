import AppKit
import RotaCore
import SwiftUI

/// The editable fields of a routine, with schedule preview.
struct RoutineForm: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: Routine
    /// Set for a new routine, whose skill names it; an existing routine keeps its id.
    var skillTaken: Bool?

    var body: some View {
        Form {
            if let skillTaken {
                // An agent routine is named after the project skill it runs; a command just needs an id.
                TextField(draft.harness.isAgent ? "Skill" : "ID", text: $draft.id,
                          prompt: Text(draft.harness.isAgent ? "the project skill this routine runs" : "weekly-backup"))
                    .accessibilityIdentifier("routineSkill")
                if skillTaken {
                    Text("A routine with this id already exists.").foregroundStyle(Color.errorText)
                }
            }
            TextField("Name", text: $draft.name)
                .accessibilityIdentifier("routineName")
            LabeledContent("Project folder") {
                HStack(spacing: 8) {
                    TextField("Project folder", text: $draft.workingDirectory, prompt: Text("/path/to/project"))
                        .labelsHidden()
                        .truncationMode(.middle)
                        .accessibilityIdentifier("routineFolder")
                    Button("Choose\u{2026}") { chooseFolder() }
                }
            }
            if !draft.workingDirectory.isEmpty && !FileManager.default.fileExists(atPath: draft.workingDirectory) {
                Label("No folder at this path.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.errorText)
                    .interfaceFont(.callout)
            }
            ScheduleField(schedule: $draft.schedule)
            // A menu, not segments: four fixed-width segments overflow a narrow window.
            InterfacePicker("Runs on", value: draft.harness.title, selection: $draft.harness) {
                ForEach(Harness.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("routineHarness")
            .onChange(of: draft.harness) {
                // Model ids and efforts belong to one harness.
                draft.model = nil
                draft.effort = nil
            }
            if draft.harness.isAgent {
                ModelPickers(draft: $draft)
            }
            TimeLimitField(minutes: $draft.timeLimitMinutes)
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.harness.isAgent ? "Prompt" : "Command")
                TextEditor(text: $draft.prompt)
                    .accessibilityLabel(draft.harness.isAgent ? "Prompt" : "Command")
                    .accessibilityIdentifier("routinePrompt")
                    .interfaceFont(.body, design: .monospaced)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !draft.workingDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.workingDirectory)
        }
        if panel.runModal() == .OK, let url = panel.url {
            draft.workingDirectory = url.path
        }
    }
}

private struct ScheduleField: View {
    @Binding var schedule: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Schedule") {
                HStack(spacing: 8) {
                    TextField("Schedule", text: $schedule, prompt: Text("minute hour day month weekday"))
                        .accessibilityIdentifier("routineSchedule")
                        .labelsHidden()
                        .interfaceFont(.body, design: .monospaced)
                        .multilineTextAlignment(.trailing)
                    // Common schedules, so a first routine needs no cron.
                    Menu {
                        ForEach(ScheduleText.presets, id: \.self) { cron in
                            Button(ScheduleText.describe(cron) ?? cron) { schedule = cron }
                        }
                    } label: {
                        Image(systemName: "clock")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Common schedules")
                    .accessibilityLabel("Common schedules")
                    .accessibilityIdentifier("schedulePresets")
                }
            }
            Group {
                switch Result(catching: { try CronSchedule(schedule) }) {
                case .success(let cron):
                    let times = cron.upcoming(after: .now, count: 3)
                    let next = times.isEmpty ? "Never fires" :
                        "Next: " + times.map { $0.formatted(date: .abbreviated, time: .shortened) }
                            .joined(separator: ", ")
                    Text([ScheduleText.describe(schedule), next].compactMap { $0 }.joined(separator: ". "))
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(Color.errorText)
                }
            }
            .interfaceFont(.caption)
            .foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The model a routine runs on and its reasoning effort, from what the
/// harness's CLI lists. Default leaves the choice to the CLI.
private struct ModelPickers: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: Routine

    var body: some View {
        let options = model.settings.models[draft.harness] ?? []
        let selected = options.first { $0.id == draft.model } ?? options.first(where: \.isDefault)
            ?? (draft.model == nil ? options.first : nil)
        InterfacePicker("Model", value: draft.model.map { id in
            options.first { $0.id == id }?.title ?? id
        } ?? (options.first(where: \.isDefault).map { "Default (\($0.title))" } ?? "Default"),
                        selection: $draft.model) {
            Text(options.first(where: \.isDefault).map { "Default (\($0.title))" } ?? "Default")
                .tag(String?.none)
            Divider()
            if options.isEmpty { Text("Model List Unavailable").disabled(true) }
            ForEach(options) { Text($0.title).tag(Optional($0.id)) }
            if let current = draft.model, !options.contains(where: { $0.id == current }) {
                Text(current).tag(Optional(current))
            }
        }
        .accessibilityIdentifier("routineModel")
        .onChange(of: draft.model) {
            if let effort = draft.effort, let selected, !selected.efforts.contains(effort) { draft.effort = nil }
        }
        InterfacePicker("Effort", value: draft.effort?.capitalized ?? "Default", selection: $draft.effort) {
            Text("Default").tag(String?.none)
            Divider()
            ForEach(selected?.efforts ?? [], id: \.self) { Text($0.capitalized).tag(Optional($0)) }
            if let current = draft.effort, selected?.efforts.contains(current) != true {
                Text(current.capitalized).tag(Optional(current))
            }
        }
        .accessibilityIdentifier("routineEffort")
        .disabled(selected?.efforts.isEmpty ?? true)
    }
}

/// Off by default: a run takes as long as it needs. On, Rota stops a run that
/// passes the limit and records it as timed out.
private struct TimeLimitField: View {
    @Binding var minutes: Int?

    var body: some View {
        Toggle("Time limit", isOn: Binding(
            get: { minutes != nil },
            set: { minutes = $0 ? 60 : nil }
        ))
        .accessibilityIdentifier("routineTimeLimit")
        if let limit = minutes {
            Stepper(value: Binding(get: { limit }, set: { minutes = $0 }), in: 5...1440, step: 5) {
                LabeledContent("Stop a run after", value: Self.text(limit))
            }
        }
    }

    static func text(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min"
            : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

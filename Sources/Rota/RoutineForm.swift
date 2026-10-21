import AppKit
import RotaCore
import SwiftUI

/// The editable fields of a routine, with schedule preview.
struct RoutineForm: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    @Binding var draft: Routine
    /// Set for a new routine, whose skill names it; an existing routine keeps its id.
    var skillTaken: Bool?
    @Namespace private var promptLabel

    var body: some View {
        Form {
            // First: the agent decides its models and whether the id field names a skill.
            // A menu, not segments: four fixed-width segments overflow a narrow window.
            InterfacePicker(title: "Runs on", selection: $draft.harness,
                            choices: Harness.allCases.map { .item($0.title, $0) }, identifier: "routineHarness")
            .onChange(of: draft.harness) {
                // Model ids and efforts belong to one harness.
                draft.model = nil
                draft.effort = nil
            }
            if draft.harness.isAgent {
                ModelPickers(draft: $draft)
            }
            if let skillTaken {
                // An agent routine is named after the project skill it runs; a command just needs an id.
                TextField(draft.harness.isAgent ? "Skill" : "ID", text: $draft.id,
                          prompt: Text(draft.harness.isAgent ? "the project skill this routine runs" : "weekly-backup"))
                    .accessibilityIdentifier("routineSkill")
                if skillTaken {
                    Text(draft.harness.isAgent ? "A routine with this skill already exists."
                         : "A routine with this ID already exists.")
                        .foregroundStyle(Color.errorText)
                }
            }
            TextField("Name", text: $draft.name)
                .accessibilityIdentifier("routineName")
            LabeledContent("Project folder") {
                HStack {
                    TextField("Project folder", text: $draft.workingDirectory, prompt: Text("/path/to/project"))
                        .labelsHidden()
                        .truncationMode(.middle)
                        .accessibilityIdentifier("routineFolder")
                    Button(interfaceTitle: "Choose\u{2026}") { chooseFolder() }
                }
            }
            .labeledContentStyle(InterfaceFormRowStyle())
            if !draft.workingDirectory.isEmpty && !FileManager.default.fileExists(atPath: draft.workingDirectory) {
                Label("No folder at this path.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.errorText)
                    .interfaceFont(.callout)
            }
            // What it does before when: the sheet opens with the prompt in view.
            VStack(alignment: .leading, spacing: metrics.points(6)) {
                Text(draft.harness.isAgent ? "Prompt" : "Command")
                    .accessibilityLabeledPair(role: .label, id: "prompt", in: promptLabel)
                // Paired with its title, as the other fields are; an accessibilityLabel on the
                // editor's wrapper made AXPress on the sheet's Add report failure.
                TextEditor(text: $draft.prompt)
                    .accessibilityIdentifier("routinePrompt")
                    .accessibilityLabeledPair(role: .content, id: "prompt", in: promptLabel)
                    .interfaceFont(.body).monospaced()
                    .frame(minHeight: metrics.points(90))
                    .scrollContentBackground(.hidden)
                    .padding(metrics.points(4))
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: metrics.points(6)))
            }
            ScheduleField(schedule: $draft.schedule)
            TimeLimitField(minutes: $draft.timeLimitMinutes)
        }
        .formStyle(.grouped)
        .toggleStyle(InterfaceFormToggleStyle())
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
    @Environment(\.interfaceScale) private var metrics
    @Binding var schedule: String

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(4)) {
            LabeledContent("Schedule") {
                HStack(spacing: metrics.points(8)) {
                    TextField("Schedule", text: $schedule, prompt: Text("minute hour day month weekday"))
                        .accessibilityIdentifier("routineSchedule")
                        .labelsHidden()
                        .interfaceFont(.body).monospaced()
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
            .labeledContentStyle(InterfaceFormRowStyle())
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
        let loading = model.settings.loadingModels.contains(draft.harness)
        // Legacy aliases display their current resolved version without rewriting the routine.
        let selected = options.first { $0.matches(draft.model) } ?? options.first(where: \.isDefault)
            ?? (draft.model == nil ? options.first : nil)
        let modelChoices: [InterfaceChoice<String?>] = [
            .item(options.first(where: \.isDefault).map { "Default (\($0.title))" } ?? "Default", nil), .separator
        ] + options.map { .item($0.title, $0.id) } + missingModel(options: options)
        InterfacePicker(title: "Model", selection: Binding(
            get: { options.first { $0.matches(draft.model) }?.id ?? draft.model },
            set: { draft.model = $0 }
        ), choices: modelChoices, identifier: "routineModel")
        .onChange(of: draft.model) {
            if let effort = draft.effort, let selected, !selected.efforts.contains(effort) { draft.effort = nil }
        }
        let efforts = selected?.efforts ?? []
        let effortChoices: [InterfaceChoice<String?>] = [
            .item(selected == nil ? (loading ? "Loading…" : "Unavailable")
                : (efforts.isEmpty ? "Not supported" : "Default"), nil), .separator
        ] + efforts.map { .item($0.capitalized, $0) } + missingEffort(efforts)
        InterfacePicker(title: "Effort", selection: $draft.effort,
                        choices: effortChoices, identifier: "routineEffort")
        .disabled(selected?.efforts.isEmpty ?? true)
        if options.isEmpty {
            Text(loading ? "Loading models…" : "Couldn't load models. Check the agent in Settings.")
                .interfaceFont(.caption)
                .foregroundStyle(Color.secondaryText)
                .accessibilityIdentifier("routineModelsStatus")
        }
    }

    private func missingModel(options: [ModelOption]) -> [InterfaceChoice<String?>] {
        guard let current = draft.model, !options.contains(where: { $0.matches(current) }) else { return [] }
        return [.item(current, current)]
    }

    private func missingEffort(_ efforts: [String]) -> [InterfaceChoice<String?>] {
        guard let current = draft.effort, !efforts.contains(current) else { return [] }
        return [.item(current.capitalized, current)]
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
            LabeledContent("Stop a run after") {
                HStack {
                    Text(Self.text(limit))
                    Stepper("Stop a run after", value: Binding(get: { limit }, set: { minutes = $0 }),
                            in: 5...1440, step: 5)
                        .labelsHidden()
                        .accessibilityIdentifier("routineTimeLimitValue")
                }
                .fixedSize()
            }
            .labeledContentStyle(InterfaceFormRowStyle())
        }
    }

    static func text(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min"
            : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

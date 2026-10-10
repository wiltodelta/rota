import AppKit
import RotaCore
import SwiftUI

/// The editable fields of a routine, with schedule preview and harness warnings.
struct RoutineForm: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: Routine
    /// Set for a new routine, whose skill names it; an existing routine keeps its id.
    var skillTaken: Bool?

    var body: some View {
        Form {
            if let skillTaken {
                TextField("Skill", text: $draft.id, prompt: Text("the project skill this routine runs"))
                    .accessibilityIdentifier("routineSkill")
                if skillTaken {
                    Text("A routine for this skill already exists.").foregroundStyle(.red)
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
                    Button("Choose\u{2026}") { chooseFolder() }
                }
            }
            if !draft.workingDirectory.isEmpty && !FileManager.default.fileExists(atPath: draft.workingDirectory) {
                Label("No folder at this path.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            ScheduleField(schedule: $draft.schedule)
            // A menu, not segments: four fixed-width segments overflow a narrow window.
            Picker("Runs on", selection: $draft.harness) {
                ForEach(Harness.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("routineHarness")
            HarnessWarnings(routine: draft)
            Stepper(value: $draft.timeoutMinutes, in: 5...480, step: 5) {
                LabeledContent("Time limit", value: "\(draft.timeoutMinutes) min")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.harness.isAgent ? "Prompt" : "Command")
                TextEditor(text: $draft.prompt)
                    .accessibilityIdentifier("routinePrompt")
                    .font(.body.monospaced())
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
                TextField("Schedule", text: $schedule, prompt: Text("minute hour day month weekday"))
                    .accessibilityIdentifier("routineSchedule")
                    .labelsHidden()
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
            }
            Group {
                switch Result(catching: { try CronSchedule(schedule) }) {
                case .success(let cron):
                    let times = cron.upcoming(after: .now, count: 3)
                    Text(times.isEmpty ? "Never fires" :
                         "Next: " + times.map { $0.formatted(date: .abbreviated, time: .shortened) }
                            .joined(separator: ", "))
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Explains which tools the skill uses that the chosen harness lacks.
struct HarnessWarnings: View {
    @Environment(AppModel.self) private var model
    let routine: Routine

    var body: some View {
        let needs = model.scheduler.requirements(of: routine)
        let gaps = SkillRequirements.gaps(needs, on: routine.harness)
        if !gaps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(gaps, id: \.0) { capability, support in
                    Label(message(capability, support), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(support == .missing ? .red : .orange)
                }
            }
            .font(.callout)
        } else if !needs.isEmpty {
            Text("Uses " + needs.map(\.title).sorted().joined(separator: " and ") + ", available here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func message(_ capability: Capability, _ support: CapabilitySupport) -> String {
        switch support {
        case .native:
            return ""
        case .differentTools(let detail):
            return "The skill uses \(capability.title). \(detail)"
        case .missing:
            return "The skill uses \(capability.title), which \(routine.harness.title) does not have."
        }
    }
}

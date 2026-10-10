import RotaCore
import SwiftUI

/// Lists Claude Desktop's routines and copies the chosen ones into Rota, turned off.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ClaudeDesktopImport.Candidate] = []
    @State private var chosen: Set<String> = []
    @State private var harness: Harness = .claude
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Claude Desktop").font(.headline)
            Text("""
                Imported routines start turned off. Turn each one off in Claude Desktop before \
                turning it on here, or both apps will run it.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
            List(candidates) { candidate in
                Toggle(isOn: Binding(
                    get: { chosen.contains(candidate.id) },
                    set: { if $0 { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.routine.name)
                        Text(detail(candidate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.scheduler.routine(candidate.id) != nil)
            }
            .frame(minHeight: 140, idealHeight: 280)
            Picker("Run on", selection: $harness) {
                ForEach(Harness.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import \(chosen.count)") { importChosen() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func detail(_ candidate: ClaudeDesktopImport.Candidate) -> String {
        var parts = [candidate.routine.schedule,
                     URL(fileURLWithPath: candidate.routine.workingDirectory).lastPathComponent]
        if model.scheduler.routine(candidate.id) != nil {
            parts.append("already in Rota")
        } else if candidate.enabledInClaudeDesktop {
            parts.append("on in Claude Desktop")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func load() {
        guard let file = ClaudeDesktopImport.locate() else {
            problem = "No Claude Desktop scheduled tasks found."
            return
        }
        do {
            candidates = try ClaudeDesktopImport.candidates(from: file)
                .sorted { $0.routine.name.localizedStandardCompare($1.routine.name) == .orderedAscending }
        } catch {
            problem = "Could not read \(file.path): \(error.localizedDescription)"
        }
    }

    private func importChosen() {
        for candidate in candidates where chosen.contains(candidate.id) {
            var routine = candidate.routine
            routine.harness = harness
            model.scheduler.save(routine)
        }
        model.selection = chosen.min().map { .routine($0) }
        dismiss()
    }
}

struct NewRoutineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    // A routine made here runs on its schedule from the start; only imports start off.
    @State private var draft = Routine(id: "", name: "", workingDirectory: "", schedule: "0 9 * * 1-5",
                                       enabled: true, prompt: "")

    private var identifierTaken: Bool { model.scheduler.routine(draft.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoutineForm(draft: $draft, skillTaken: identifierTaken)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    if draft.name.isEmpty { draft.name = draft.id }
                    model.scheduler.save(draft)
                    model.selection = .routine(draft.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("addRoutine")
                .disabled(draft.id.isEmpty || identifierTaken || draft.workingDirectory.isEmpty
                          || draft.prompt.isEmpty || (try? CronSchedule(draft.schedule)) == nil)
            }
            .padding(16)
        }
        // Fits the window at its minimum height; the form scrolls inside.
        .frame(width: 560)
        .frame(minHeight: 360, idealHeight: 520)
        .onChange(of: draft.id) { fillPrompt() }
        .onChange(of: draft.workingDirectory) { fillPrompt() }
    }

    /// Keeps the prompt on the standard handoff until the user writes their own.
    @State private var generatedPrompt = ""

    private func fillPrompt() {
        guard draft.prompt.isEmpty || draft.prompt == generatedPrompt,
              !draft.id.isEmpty, !draft.workingDirectory.isEmpty else { return }
        generatedPrompt = Routine.defaultPrompt(skill: draft.id, workingDirectory: draft.workingDirectory)
        draft.prompt = generatedPrompt
    }
}

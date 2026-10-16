import RotaCore
import SwiftUI

/// Lists the routines other apps schedule, by source, and copies the chosen
/// ones into Rota, turned off.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scans: [ImportScan]?
    @State private var chosen: Set<String> = []
    /// nil keeps each routine on the agent it ran on in its app.
    @State private var harness: Harness?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Routines").font(.headline)
            Text("Rota copies the routines you pick from other apps, turned off.")
                .font(.callout)
                .foregroundStyle(Color.secondaryText)
            if let scans {
                List {
                    ForEach(scans, id: \.source) { scan in
                        Section {
                            if scan.candidates.isEmpty {
                                Text(scan.problem ?? "No routines scheduled there.")
                                    .foregroundStyle(Color.secondaryText)
                            }
                            ForEach(scan.candidates) { ImportRow(candidate: $0, chosen: $chosen) }
                        } header: {
                            sectionHeader(scan)
                        }
                    }
                }
                .frame(minHeight: 180, idealHeight: 360)
            } else {
                ProgressView("Looking for routines\u{2026}")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
            Picker("Run on", selection: $harness) {
                Text("The same agent as in its app").tag(Harness?.none)
                Divider()
                ForEach(Harness.agents) { Text($0.title).tag(Optional($0)) }
            }
            .fixedSize()
            if stillOn > 0 {
                Label(stillOn == 1
                      ? "1 of them is still on in its app. Turn it off there before turning it on here, "
                        + "or both apps will run it."
                      : "\(stillOn) of them are still on in their apps. Turn them off there before turning "
                        + "them on here, or both apps will run them.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Import" : "Import \(chosen.count) Routine\(chosen.count == 1 ? "" : "s")") {
                    importChosen()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            let found = await Task.detached(priority: .userInitiated) { RoutineImport.scanAll() }.value
            scans = found
        }
    }

    private var candidates: [ImportCandidate] { scans?.flatMap(\.candidates) ?? [] }

    private var stillOn: Int { candidates.filter { chosen.contains($0.id) && $0.onInSource }.count }

    private func importable(_ scan: ImportScan) -> [String] {
        scan.candidates.filter { $0.unsupported == nil && model.scheduler.routine($0.routine.id) == nil }.map(\.id)
    }

    private func sectionHeader(_ scan: ImportScan) -> some View {
        let ids = importable(scan)
        let all = !ids.isEmpty && Set(ids).isSubset(of: chosen)
        return HStack {
            Text(scan.source.title)
            Spacer()
            if !ids.isEmpty {
                Button(all ? "Select None" : "Select All") {
                    if all { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    private func importChosen() {
        var first: String?
        for candidate in candidates where chosen.contains(candidate.id) {
            var routine = candidate.routine
            if let harness, harness != candidate.source.harness {
                // Model ids belong to the agent they came from.
                routine.harness = harness
                routine.model = nil
                routine.effort = nil
            }
            routine.enabled = false
            model.scheduler.save(routine)
            first = first ?? routine.id
        }
        model.selection = first.map { .routine($0) }
        dismiss()
    }
}

/// One importable routine: its name, schedule in words, folder, and whether it
/// is still on in its app, already in Rota, or cannot be imported.
private struct ImportRow: View {
    @Environment(AppModel.self) private var model
    let candidate: ImportCandidate
    @Binding var chosen: Set<String>

    var body: some View {
        let inRota = model.scheduler.routine(candidate.routine.id) != nil
        Toggle(isOn: Binding(
            get: { chosen.contains(candidate.id) },
            set: { if $0 { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) } }
        )) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.routine.name)
                    Text(detail).font(.caption).foregroundStyle(Color.secondaryText)
                    if let reason = candidate.unsupported {
                        Text(reason).font(.caption).foregroundStyle(Color.errorText)
                    }
                }
                Spacer(minLength: 8)
                if inRota {
                    Tag(text: "In Rota", color: Color.secondaryText)
                } else if candidate.onInSource {
                    Tag(text: "On in \(candidate.source.title)", color: Color.warningText)
                }
            }
        }
        .disabled(inRota || candidate.unsupported != nil)
        .help(candidate.routine.schedule)
    }

    private var detail: String {
        let routine = candidate.routine
        let schedule = ScheduleText.describe(routine.schedule) ?? routine.schedule
        var parts = [schedule, URL(fileURLWithPath: routine.workingDirectory).lastPathComponent]
        if let modelID = routine.model { parts.append(modelID) }
        return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}

/// A small capsule label for a row's state.
private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
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
        // A taken id is said under its field.
        let problem = draft.problem()
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(text: "New Routine")
            RoutineForm(draft: $draft, skillTaken: identifierTaken)
            SheetButtons(problem: problem) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if draft.name.isEmpty { draft.name = draft.id }
                    model.scheduler.save(draft)
                    model.selection = .routine(draft.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("addRoutine")
                .disabled(problem != nil || identifierTaken)
            }
        }
        // Fits the window at its minimum height; the form scrolls inside.
        .frame(width: 560)
        .frame(minHeight: 360, idealHeight: 520)
        .onChange(of: draft.id) { fillPrompt() }
        .onChange(of: draft.workingDirectory) { fillPrompt() }
        .onChange(of: draft.harness) {
            if !draft.harness.isAgent, draft.prompt == generatedPrompt {
                draft.prompt = ""
                generatedPrompt = ""
            } else if draft.harness.isAgent {
                fillPrompt()
            }
        }
    }

    /// Keeps the prompt on the standard handoff until the user writes their own.
    @State private var generatedPrompt = ""

    private func fillPrompt() {
        guard draft.harness.isAgent, draft.prompt.isEmpty || draft.prompt == generatedPrompt,
              !draft.id.isEmpty, !draft.workingDirectory.isEmpty else { return }
        generatedPrompt = Routine.defaultPrompt(skill: draft.id, workingDirectory: draft.workingDirectory)
        draft.prompt = generatedPrompt
    }
}

/// A sheet's title above its form, as the import sheet has.
struct SheetTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 18)
    }
}

/// A sheet's button row, with what still keeps it from saving on the left.
struct SheetButtons<Buttons: View>: View {
    let problem: String?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack {
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                    .accessibilityIdentifier("sheetProblem")
            }
            Spacer(minLength: 12)
            buttons
        }
        .padding(16)
    }
}

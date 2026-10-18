import RotaCore
import SwiftUI

struct NewRoutineSheet: View {
    @Environment(\.interfaceScale) private var metrics
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
                Button(interfaceTitle: "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(interfaceTitle: "Add") {
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
        .frame(width: metrics.sheetWidth(560))
        .frame(minHeight: 360, idealHeight: metrics.points(520))
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
    @Environment(\.interfaceScale) private var metrics
    let text: String

    var body: some View {
        Text(text)
            .interfaceFont(.headline)
            .padding(.horizontal, metrics.points(20))
            .padding(.top, metrics.points(18))
    }
}

/// A sheet's button row, with what still keeps it from saving on the left.
struct SheetButtons<Buttons: View>: View {
    @Environment(\.interfaceScale) private var metrics
    let problem: String?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack {
            if let problem {
                Text(problem)
                    .interfaceFont(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                    .accessibilityIdentifier("sheetProblem")
            }
            Spacer(minLength: 12)
            buttons
        }
        .padding(metrics.points(16))
    }
}

import Foundation
import Observation
import RotaCore
import SwiftUI

/// Form values and the field currently using the session's shared text editor.
/// Ordinary session drafts and attachments stay in AppModel, outside this form.
@MainActor
@Observable
final class QuestionDraft {
    let question: AgentQuestion
    var values: [String: [String]] = [:]
    var other: [String: String] = [:]
    var customFields: Set<String> = []
    var focusRequest = 0
    private(set) var fieldIndex = 0
    var failure: String?

    init(question: AgentQuestion) { self.question = question }

    func usesComposer(_ field: QuestionField) -> Bool {
        [.text, .choice, .multiple].contains(field.kind)
    }

    var currentField: QuestionField? {
        question.fields.indices.contains(fieldIndex) ? question.fields[fieldIndex] : nil
    }

    var isLastField: Bool { fieldIndex >= question.fields.count - 1 }

    var composerField: QuestionField? {
        guard let field = currentField, usesComposer(field),
              field.options.isEmpty || customFields.contains(field.id) else { return nil }
        return field
    }

    var canAdvance: Bool {
        guard let field = currentField, let action = question.actions.first else { return true }
        var step = question
        step.fields = [field]
        let emptyCustom = customFields.contains(field.id)
            && (other[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !emptyCustom && step.validationMessage(.init(action: action.id, values: answer.values)) == nil
    }

    func moveForward() {
        guard canAdvance, !isLastField else { return }
        fieldIndex += 1
        failure = nil
        focusRequest += 1
    }

    func moveBack() {
        guard fieldIndex > 0 else { return }
        fieldIndex -= 1
        failure = nil
        focusRequest += 1
    }

    var answer: QuestionAnswer {
        var combined = values
        for field in question.fields where field.options.isEmpty || customFields.contains(field.id) {
            guard let text = other[field.id], !text.isEmpty else { continue }
            if field.kind == .multiple { combined[field.id, default: []].append(text) } else {
                combined[field.id] = [text]
            }
        }
        return QuestionAnswer(values: combined)
    }

    func canSubmit(_ action: String) -> Bool {
        let emptyCustom = customFields.contains {
            (other[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !emptyCustom && question.validationMessage(.init(action: action, values: answer.values)) == nil
    }

    func selectOther(_ selected: Bool, field: QuestionField) {
        if selected {
            customFields.insert(field.id)
            if field.kind != .multiple { values[field.id] = nil }
            edit(field)
        } else {
            customFields.remove(field.id)
        }
    }

    /// Captures the field ID so an old editor cannot write into a newly selected field.
    func text(for field: QuestionField) -> Binding<String> {
        Binding(get: { self.other[field.id] ?? "" }, set: { self.other[field.id] = $0 })
    }

    func edit(_ field: QuestionField) {
        guard let index = question.fields.firstIndex(where: { $0.id == field.id }) else { return }
        fieldIndex = index
        focusRequest += 1
    }

    func send(_ action: String, submit: (QuestionAnswer) throws -> Void) {
        do {
            try submit(.init(action: action, values: answer.values))
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

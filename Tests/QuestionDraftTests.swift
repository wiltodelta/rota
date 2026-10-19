import RotaCore
@testable import Rota
import XCTest

@MainActor
final class QuestionDraftTests: XCTestCase {
    func testOtherUsesSharedInputAndKeepsItsDraftWhenChangingOptions() {
        let field = QuestionField(id: "color", title: "Color", kind: .choice,
                                  options: [.init(id: "blue", label: "Blue")], required: false)
        let draft = QuestionDraft(question: .init(title: "Choose", fields: [field]))
        XCTAssertNil(draft.composerField)
        draft.selectOther(true, field: field)
        XCTAssertEqual(draft.composerField?.id, field.id)
        XCTAssertFalse(draft.canSubmit("accept"))
        XCTAssertFalse(draft.canAdvance)
        draft.other[field.id] = "Green"
        XCTAssertEqual(draft.answer.values[field.id], ["Green"])
        XCTAssertTrue(draft.canSubmit("accept"))
        draft.selectOther(false, field: field)
        draft.values[field.id] = ["blue"]
        XCTAssertNil(draft.composerField)
        XCTAssertEqual(draft.answer.values[field.id], ["blue"])
        draft.selectOther(true, field: field)
        XCTAssertEqual(draft.other[field.id], "Green")
        XCTAssertEqual(draft.answer.values[field.id], ["Green"])
    }

    func testMultipleAnswersAndTextFieldsKeepSeparateInput() {
        let choices = QuestionField(id: "sections", title: "Sections", kind: .multiple,
                                    options: [.init(id: "one", label: "One")])
        let note = QuestionField(id: "note", title: "Note", required: false)
        let draft = QuestionDraft(question: .init(title: "Choose", fields: [choices, note]))
        XCTAssertNil(draft.composerField)
        draft.values[choices.id] = ["one"]
        draft.selectOther(true, field: choices)
        draft.other[choices.id] = "Two"
        draft.other[note.id] = "Keep this note"
        XCTAssertEqual(draft.answer.values[choices.id], ["one", "Two"])
        draft.edit(note)
        XCTAssertEqual(draft.composerField?.id, note.id)
        XCTAssertEqual(draft.answer.values[note.id], ["Keep this note"])
        draft.selectOther(false, field: choices)
        XCTAssertEqual(draft.answer.values[choices.id], ["one"])
    }

    func testNavigationValidatesOnlyTheCurrentFieldAndPreservesAnswers() {
        let first = QuestionField(id: "format", title: "Format", kind: .choice,
                                  options: [.init(id: "short", label: "Short")])
        let note = QuestionField(id: "note", title: "Note")
        let draft = QuestionDraft(question: .init(title: "Report", fields: [first, note]))
        XCTAssertEqual(draft.currentField?.id, first.id)
        XCTAssertFalse(draft.canAdvance)
        draft.moveForward()
        XCTAssertEqual(draft.currentField?.id, first.id)
        draft.values[first.id] = ["short"]
        XCTAssertTrue(draft.canAdvance)
        draft.moveForward()
        XCTAssertEqual(draft.currentField?.id, note.id)
        XCTAssertTrue(draft.isLastField)
        XCTAssertEqual(draft.composerField?.id, note.id)
        XCTAssertFalse(draft.canAdvance)
        XCTAssertFalse(draft.canSubmit("accept"))
        draft.other[note.id] = "Additional context"
        draft.moveBack()
        XCTAssertEqual(draft.currentField?.id, first.id)
        XCTAssertNil(draft.composerField)
        XCTAssertEqual(draft.answer.values[note.id], ["Additional context"])
        draft.moveForward()
        XCTAssertTrue(draft.canSubmit("accept"))
    }

    func testAnOldEditorBindingCannotOverwriteTheNewlySelectedField() {
        let first = QuestionField(id: "first", title: "First")
        let second = QuestionField(id: "second", title: "Second")
        let draft = QuestionDraft(question: .init(title: "Details", fields: [first, second]))
        let oldEditor = draft.text(for: first)
        draft.edit(second)
        let newEditor = draft.text(for: second)
        newEditor.wrappedValue = "Second answer"
        oldEditor.wrappedValue = "Late first answer"
        XCTAssertEqual(draft.other[first.id], "Late first answer")
        XCTAssertEqual(draft.other[second.id], "Second answer")
        XCTAssertEqual(draft.composerField?.id, second.id)
    }

    func testTypedFieldsRemainSpecializedAndSubmissionPreservesFailures() {
        let secret = QuestionField(id: "token", title: "Token", kind: .secret)
        let number = QuestionField(id: "count", title: "Count", kind: .integer)
        let draft = QuestionDraft(question: .init(title: "Credentials", fields: [secret, number]))
        XCTAssertNil(draft.composerField)
        draft.other[secret.id] = "synthetic-secret"
        draft.other[number.id] = "3"
        var submitted: QuestionAnswer?
        draft.send("accept") { submitted = $0 }
        XCTAssertEqual(submitted?.values[number.id], ["3"])
        draft.send("accept") { _ in throw ControlError("Try again") }
        XCTAssertEqual(draft.failure, "Try again")
        XCTAssertEqual(draft.other[secret.id], "synthetic-secret")
    }
}

@testable import Rota
@testable import RotaCore
import XCTest

final class QuestionAnswerDraftTests: XCTestCase {
    private func question() throws -> SessionRequest.Question {
        let request = try XCTUnwrap(RequestPresentation.claude(["tool_name": "AskUserQuestion", "input": [
            "questions": [["question": "Which sections?", "multiSelect": true, "options": [
                ["label": "Summary, details"], ["label": "Данные, графики"]]]]]]))
        return try XCTUnwrap(request.questions.first)
    }

    func testMultipleOptionLabelsWithCommasRemainSelectedAndCanBeRemoved() throws {
        let question = try question()
        var draft = QuestionAnswerDraft()
        for option in question.options { draft.select(question.id, option: option, selected: true) }
        XCTAssertTrue(draft.isSelected(question.id, option: question.options[0]))
        XCTAssertTrue(draft.isSelected(question.id, option: question.options[1]))
        XCTAssertEqual(draft.values(for: [question])[question.id], "Summary, details, Данные, графики")
        draft.select(question.id, option: question.options[0], selected: false)
        XCTAssertFalse(draft.isSelected(question.id, option: question.options[0]))
        XCTAssertTrue(draft.isSelected(question.id, option: question.options[1]))
        XCTAssertEqual(draft.value(for: question), "Данные, графики")
    }

    func testOtherTextDoesNotReplaceCheckedOptionsAndKeepsItsWhitespace() throws {
        let question = try question()
        var draft = QuestionAnswerDraft()
        draft.select(question.id, option: question.options[0], selected: true)
        draft.text[question.id] = "  Other section  "
        XCTAssertTrue(draft.isSelected(question.id, option: question.options[0]))
        XCTAssertEqual(draft.value(for: question), "Summary, details,   Other section  ")
    }
}

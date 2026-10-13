@testable import RotaCore
import XCTest

final class SessionRequestTests: XCTestCase {
    func testInvalidAndLateChoicesCannotApproveAnything() {
        var updates: [[SessionRequest]] = []
        let pending = SessionRequests { updates.append($0) }
        let request = RequestPresentation.permission(title: "Run?", detail: "echo sample")
        var replies: [SessionResponse] = []
        var cancelled = 0
        pending.add(request, answer: { replies.append($0) }, cancel: { cancelled += 1 })
        XCTAssertEqual(updates.last?.count, 1)
        XCTAssertFalse(pending.answer(request.id, .init(choice: "allow_always")))
        XCTAssertTrue(replies.isEmpty)
        pending.cancelAll()
        XCTAssertEqual(cancelled, 1)
        XCTAssertFalse(pending.answer(request.id, .init(choice: "allow")))
        pending.cancelAll()
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(updates.last, [])
    }

    func testRepliesOwnSeparateRequestsAndConsumeEachExactlyOnce() {
        let pending = SessionRequests { _ in }
        let first = RequestPresentation.permission(title: "Run?", detail: "same command")
        let second = RequestPresentation.permission(title: "Run?", detail: "same command")
        var replies: [String] = []
        pending.add(first, answer: { replies.append("first:" + $0.choice) }, cancel: {})
        pending.add(second, answer: { replies.append("second:" + $0.choice) }, cancel: {})
        XCTAssertTrue(pending.answer(second.id, .init(choice: "deny")))
        XCTAssertFalse(pending.answer(second.id, .init(choice: "allow")))
        XCTAssertTrue(pending.answer(first.id, .init(choice: "allow")))
        XCTAssertEqual(replies, ["second:deny", "first:allow"])
    }

    func testQuestionValidationAndExactCodexResponse() throws {
        let params: [String: Any] = ["questions": [["id": "destination", "question": "Which destination?",
            "options": [["label": "Local", "description": "Keep it local"]], "isOther": false]]]
        let request = try XCTUnwrap(RequestPresentation.codex("item/tool/requestUserInput", params))
        let pending = SessionRequests { _ in }
        var reply: SessionResponse?
        pending.add(request, answer: { reply = $0 }, cancel: {})
        XCTAssertFalse(pending.answer(request.id, .init(choice: "submit")))
        XCTAssertFalse(pending.answer(request.id, .init(choice: "submit", answers: ["destination": "Remote"])))
        XCTAssertTrue(pending.answer(request.id, .init(choice: "submit", answers: ["destination": "Local"])))
        let wire = RequestPresentation.codexResponse("item/tool/requestUserInput", params, try XCTUnwrap(reply))
        let encoded = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
        XCTAssertEqual(lossyUTF8(encoded), #"{"answers":{"destination":{"answers":["Local"]}}}"#)
    }

    func testClaudeQuestionsReturnAnswersByQuestionTextAndPreserveTheToolInput() throws {
        let params: [String: Any] = ["tool_name": "AskUserQuestion", "input": ["questions": [
            ["question": "Which output?", "options": [["label": "Local", "description": "Save locally"]]],
            ["question": "Which sections?", "multiSelect": true,
             "options": [["label": "Start"], ["label": "End"]]]]]]
        let request = try XCTUnwrap(RequestPresentation.claude(params))
        XCTAssertEqual(request.questions.map(\.id), ["0", "1"])
        let result = RequestPresentation.claudeResponse(params, .init(choice: "submit",
            answers: ["0": "Local", "1": "Start, End"]))
        XCTAssertEqual(result["behavior"] as? String, "allow")
        let input = try XCTUnwrap(result["updatedInput"] as? [String: Any])
        XCTAssertEqual(input["answers"] as? [String: String],
                       ["Which output?": "Local", "Which sections?": "Start, End"])
        XCTAssertEqual((input["questions"] as? [[String: Any]])?.count, 2)
    }

    func testGrokReturnsProviderOptionIDsWithoutOfferingDurableApproval() throws {
        let params: [String: Any] = ["toolCall": ["title": "Read sample"], "options": [
            ["optionId": "opaque-yes", "name": "Allow once", "kind": "allow_once"],
            ["optionId": "opaque-no", "name": "Deny once", "kind": "reject_once"],
            ["optionId": "opaque-always", "name": "Always", "kind": "allow_always"]]]
        let request = try XCTUnwrap(RequestPresentation.grok(params))
        XCTAssertEqual(request.choices.map(\.id), ["opaque-yes", "opaque-no"])
    }
}

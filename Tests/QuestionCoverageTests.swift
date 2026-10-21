import XCTest

@testable import RotaCore

final class QuestionCoverageTests: XCTestCase {
    func testEveryCodexApprovalFamilyPreservesAnExplicitRefusal() throws {
        for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                       "item/permissions/requestApproval", "execCommandApproval", "applyPatchApproval"] {
            let request = try XCTUnwrap(QuestionRequest.codex(method, ["command": "fixture"]))
            for action in ["decline", "cancel"] {
                try request.question.validate(.init(action: action))
                let response = request.response(.init(action: action))
                XCTAssertFalse(QuestionRequest.json(response).contains("accept"), method)
                XCTAssertFalse(QuestionRequest.json(response).contains("approved\""), method)
            }
        }
    }

    func testGrokExtensionAliasesAndPermissionOptions() throws {
        for prefix in ["_x.ai/", "x.ai/"] {
            let input = try XCTUnwrap(QuestionRequest.grok(prefix + "ask_user_question", [
                "questions": [["question": "Which?", "options": [["label": "Blue"]]]]
            ]))
            XCTAssertEqual(input.response(.init(values: ["Which?": ["Blue"]]))["outcome"] as? String, "accepted")
            let plan = try XCTUnwrap(QuestionRequest.grok(prefix + "exit_plan_mode", ["planContent": "A safe plan"]))
            XCTAssertEqual(plan.question.detail, "A safe plan")
            XCTAssertEqual(plan.response(.init())["outcome"] as? String, "approved")
            XCTAssertEqual(plan.response(.init(action: "cancel"))["outcome"] as? String, "abandoned")
            let form = try XCTUnwrap(QuestionRequest.grok(prefix + "mcp/elicit", ["message": "Details"]))
            XCTAssertEqual(form.response(.init(action: "decline"))["outcome"] as? String, "decline")
        }
        let permission = try XCTUnwrap(QuestionRequest.grok("session/request_permission", [
            "options": [["optionId": "deny", "name": "Deny", "kind": "reject_once"],
                        ["optionId": "allow", "name": "Allow", "kind": "allow_once"]]
        ]))
        XCTAssertEqual(permission.question.actions.map(\.id), ["deny", "allow"])
        let denied = permission.response(.init(action: "deny"))["outcome"] as? [String: String]
        XCTAssertEqual(denied?["optionId"], "deny")
        XCTAssertEqual((permission.response(.init(action: "cancel"))["outcome"] as? [String: String])?["outcome"],
                       "cancelled")
    }

    func testClaudePlanAndPermissionHooksDoNotInventConsent() throws {
        let plan = try XCTUnwrap(QuestionRequest.claude([
            "hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "tool_input": ["plan": "Plan text"],
        ]))
        XCTAssertEqual(plan.question.detail, "Plan text")
        let denied = plan.response(.init(action: "cancel"))["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(denied?["permissionDecision"] as? String, "deny")
        let request = try XCTUnwrap(QuestionRequest.claude([
            "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "fixture"],
        ]))
        let output = request.response(.init())["hookSpecificOutput"] as? [String: Any]
        let decision = output?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        XCTAssertEqual((decision?["updatedInput"] as? [String: String])?["command"], "fixture")
        let decline = request.response(.init(action: "decline"))["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual((decline?["decision"] as? [String: Any])?["behavior"] as? String, "deny")
    }

    func testEveryMCPFormModePreservesTypesAndOmitsUnansweredOptionalFields() throws {
        for mode in ["form", "openai/form", "openaiForm"] {
            let request = try XCTUnwrap(QuestionRequest.elicitation([
                "mode": mode, "requestedSchema": ["type": "object", "properties": [
                    "optionalFlag": ["type": "boolean"], "optionalText": ["type": "string"],
                    "count": ["type": "integer"], "price": ["type": "number"],
                    "flag": ["type": "boolean"],
                    "choice": ["type": "string", "oneOf": [["const": "blue", "title": "Blue"]]],
                    "tags": ["type": "array", "items": ["enum": ["one", "two"]]],
                ]],
            ]))
            let answer = QuestionAnswer(values: ["count": ["2"], "price": ["1.5"], "flag": ["false"],
                                                  "choice": ["blue"], "tags": ["one", "two"]])
            try request.question.validate(answer)
            let content = try XCTUnwrap(request.response(answer)["content"] as? [String: Any])
            XCTAssertNil(content["optionalFlag"], mode)
            XCTAssertNil(content["optionalText"], mode)
            XCTAssertEqual(content["count"] as? Int, 2)
            XCTAssertEqual(content["price"] as? Double, 1.5)
            XCTAssertEqual(content["flag"] as? Bool, false)
            XCTAssertEqual(content["choice"] as? String, "blue")
            XCTAssertEqual(content["tags"] as? [String], ["one", "two"])
            for action in ["decline", "cancel"] {
                XCTAssertEqual(request.response(.init(action: action))["action"] as? String, action)
                XCTAssertTrue(request.response(.init(action: action))["content"] is NSNull)
            }
        }
    }

    func testCodexCompletedAsyncItemReachesTheHostThroughTheRunner() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let asked = expectation(description: "async metadata reaches RunEvents")
        let journal = RunJournal(output: try FileHandle(forWritingTo: file), events: RunEvents(
            session: { _ in }, finished: { _ in }, question: { question, _ in
                XCTAssertEqual(question.fields.map(\.title), ["Choose?"])
                XCTAssertEqual(question.replyViaMessage, true)
                asked.fulfill()
            }))
        let spec = LaunchSpec(executable: "/bin/false", prompt: "", arguments: [], workingDirectory: folder.path,
                              environment: [:], mode: .codexDaemon, timeout: nil, log: file, resume: "owned-thread")
        let runner = CodexDaemonRun(spec: spec, journal: journal)
        runner.handle("item/completed", ["threadId": "owned-thread", "item": [
            "id": "call-synthetic", "type": "agentMessage", "delivery": "async", "text": "Choose?",
            "questions": [["title": "Choose?", "options": ["One", "Two"]]],
        ]])
        wait(for: [asked], timeout: 2)
        journal.finish(.succeeded)
    }

    func testExtendedFormsNeverSilentlyCoerceNestedObjectsToStrings() throws {
        let request = try XCTUnwrap(QuestionRequest.elicitation([
            "mode": "openai/form", "requestedSchema": ["type": "object", "properties": [
                "nested": ["type": "object", "properties": ["flag": ["type": "boolean"]]]
            ]],
        ]))
        XCTAssertTrue(request.question.actions.isEmpty)
        XCTAssertThrowsError(try request.question.validate(.init()))
        XCTAssertEqual(request.response(.init())["action"] as? String, "cancel")
    }

    func testDeviceVerificationCannotBeReplacedByAnOrdinaryApproval() throws {
        let request = try XCTUnwrap(QuestionRequest.elicitation([
            "mode": "openai/userVerification", "title": "Verify", "description": "Sensitive action",
            "challenge": "synthetic-challenge",
        ]))
        XCTAssertTrue(request.question.actions.isEmpty)
        XCTAssertThrowsError(try request.question.validate(.init()))
        XCTAssertEqual(request.response(.init())["action"] as? String, "cancel")
        XCTAssertNil(request.response(.init())["content"])
        XCTAssertEqual(request.response(.init(action: "decline"))["action"] as? String, "decline")
    }
}

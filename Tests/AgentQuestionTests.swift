import XCTest

@testable import RotaCore

final class AgentQuestionTests: XCTestCase {
    func testClaudeQuestionsPreserveInputAndReturnSelectedAndTypedAnswers() throws {
        let input: [String: Any] = [
            "questions": [
                [
                    "question": "Which color?", "header": "Color", "multiSelect": true,
                    "options": [
                        ["label": "Blue", "description": "Blue ink"], ["label": "Green", "description": "Green ink"],
                    ],
                ],
                ["question": "Your note?", "options": []],
            ]
        ]
        let request = try XCTUnwrap(
            QuestionRequest.claude([
                "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": input,
            ]))
        XCTAssertEqual(request.question.fields.map(\.kind), [.multiple, .text])
        let answer = QuestionAnswer(values: ["Which color?": ["Blue", "Green"], "Your note?": ["Привет"]])
        try request.question.validate(answer)
        let output = try XCTUnwrap(request.response(answer)["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["questions"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(
            updated["answers"] as? [String: String], ["Which color?": "Blue, Green", "Your note?": "Привет"])
        let canceled = try XCTUnwrap(request.response(.init(action: "cancel"))["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(canceled["permissionDecision"] as? String, "deny")
        XCTAssertNil(canceled["updatedInput"])
    }

    func testCodexQuestionIDsAndSecretInput() throws {
        let request = try XCTUnwrap(
            QuestionRequest.codex(
                "item/tool/requestUserInput",
                [
                    "questions": [
                        [
                            "id": "color", "header": "Color", "question": "Which color?", "isOther": true,
                            "options": [["label": "Blue", "description": "Blue ink"]],
                        ],
                        ["id": "token", "header": "Token", "question": "Token?", "isSecret": true],
                    ]
                ]))
        XCTAssertEqual(request.question.fields.map(\.id), ["color", "token"])
        XCTAssertEqual(request.question.fields.last?.kind, .secret)
        let answer = QuestionAnswer(values: ["color": ["Purple"], "token": ["synthetic"]])
        try request.question.validate(answer)
        let response = request.response(answer)["answers"] as? [String: [String: [String]]]
        XCTAssertEqual(response?["color"]?["answers"], ["Purple"])
        XCTAssertEqual((request.response(.init(action: "cancel"))["answers"] as? [String: Any])?.count, 0)
    }

    func testGrokCapturedQuestionWireRoundTripsWithoutCustomNotification() throws {
        let request = try XCTUnwrap(
            QuestionRequest.grok(
                "_x.ai/ask_user_question",
                [
                    "sessionId": "test", "toolCallId": "call-test", "mode": "default",
                    "questions": [
                        [
                            "question": "Which color?", "options": [["label": "Blue", "description": "Blue"]],
                            "multiSelect": false,
                        ]
                    ],
                ]))
        let response = request.response(.init(values: ["Which color?": ["Blue"]]))
        XCTAssertEqual(response["outcome"] as? String, "accepted")
        XCTAssertEqual(response["answers"] as? [String: [String]], ["Which color?": ["Blue"]])
        XCTAssertEqual(request.response(.init(action: "cancel"))["outcome"] as? String, "cancelled")
    }

    func testGrokToolSchemaSupportsMultipleSelectionAndOptionPreviews() throws {
        let request = try XCTUnwrap(QuestionRequest.grok("_x.ai/ask_user_question", [
            "questions": [[
                "question": "Which sections?", "multi_select": true,
                "options": [["label": "Summary", "description": "Overview", "preview": "Sample summary"]],
            ]]
        ]))
        XCTAssertEqual(request.question.fields.first?.kind, .multiple)
        XCTAssertEqual(request.question.fields.first?.options.first?.detail, "Overview\n\nSample summary")
        let answer = QuestionAnswer(values: ["Which sections?": ["Summary", "Custom section"]])
        try request.question.validate(answer)
        XCTAssertEqual(request.response(answer)["answers"] as? [String: [String]], answer.values)
    }

    func testMCPPrimitiveFormTypesAndConstraints() throws {
        let schema: [String: Any] = [
            "type": "object", "required": ["count", "agree", "tags"],
            "properties": [
                "count": ["type": "integer", "minimum": 1, "maximum": 5],
                "agree": ["type": "boolean"],
                "tags": [
                    "type": "array", "minItems": 1, "maxItems": 2,
                    "items": ["anyOf": [["const": "a", "title": "First"], ["const": "b", "title": "Second"]]],
                ],
                "note": ["type": "string", "maxLength": 5],
            ],
        ]
        let request = try XCTUnwrap(
            QuestionRequest.codex(
                "mcpServer/elicitation/request",
                [
                    "mode": "form", "serverName": "fixture", "message": "Details?", "requestedSchema": schema,
                ]))
        var answer = QuestionAnswer(values: ["count": ["3"], "agree": ["false"], "tags": ["a", "b"]])
        try request.question.validate(answer)
        let content = try XCTUnwrap(request.response(answer)["content"] as? [String: Any])
        XCTAssertEqual(content["count"] as? Double, 3)
        XCTAssertEqual(content["agree"] as? Bool, false)
        XCTAssertEqual(content["tags"] as? [String], ["a", "b"])
        XCTAssertNil(content["note"])
        for invalid in ["0", "6", "1.5", "NaN"] {
            answer.values["count"] = [invalid]
            XCTAssertThrowsError(try request.question.validate(answer), invalid)
        }
        XCTAssertTrue(request.response(.init(action: "decline"))["content"] is NSNull)
    }

    func testPlanAndPermissionRequestsReturnTheNativeDecisions() throws {
        let grok = try XCTUnwrap(QuestionRequest.grok("_x.ai/exit_plan_mode", ["planContent": "Say hello."]))
        XCTAssertEqual(grok.response(.init())["outcome"] as? String, "approved")
        XCTAssertEqual(grok.response(.init(action: "cancel"))["outcome"] as? String, "abandoned")
        let claude = try XCTUnwrap(
            QuestionRequest.claude([
                "hook_event_name": "PermissionRequest",
                "tool_name": "Bash", "tool_input": ["command": "echo fixture"],
            ]))
        let accepted = try XCTUnwrap(claude.response(.init())["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual((accepted["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        let declined = try XCTUnwrap(claude.response(.init(action: "decline"))["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual((declined["decision"] as? [String: Any])?["behavior"] as? String, "deny")
        let legacy = try XCTUnwrap(QuestionRequest.codex("execCommandApproval", ["command": ["echo", "fixture"]]))
        XCTAssertEqual(legacy.response(.init(action: "cancel"))["decision"] as? String, "abort")
        let denial = legacy.response(.init(action: "decline"))["decision"] as? [String: [String: String]]
        XCTAssertEqual(denial?["denied"]?["rejection"], "The user declined.")
    }

    func testDismissalControlsMatchTheProviderWithoutDuplicatingOfferedDecisions() throws {
        let input = try XCTUnwrap(QuestionRequest.codex("item/tool/requestUserInput", ["questions": []]))
        XCTAssertEqual(input.question.allowsDecline, false)
        let approval = try XCTUnwrap(QuestionRequest.codex("item/commandExecution/requestApproval", [:]))
        XCTAssertEqual(approval.question.allowsDecline, true)
        XCTAssertEqual(approval.question.actions.map(\.id), ["0", "1"])
        XCTAssertEqual(approval.response(.init(action: "1"))["decision"] as? String, "acceptForSession")
        XCTAssertEqual(approval.response(.init(action: "decline"))["decision"] as? String, "decline")
        let form = try XCTUnwrap(QuestionRequest.elicitation(["mode": "form"]))
        XCTAssertEqual(form.question.allowsDecline, true)
        let old = Data(#"{"id":"old","title":"Question","detail":"","fields":[],"actions":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentQuestion.self, from: old).allowsDecline)
    }

    func testIntegerAndUnicodeFormValuesKeepTheirWirePrecision() throws {
        let field = QuestionField(id: "count", title: "Count", kind: .integer)
        try field.validate(["9007199254740993"])
        let content = try XCTUnwrap(field.content(["9007199254740993"]))
        XCTAssertEqual(QuestionRequest.json(["count": content]), "{\n  \"count\" : 9007199254740993\n}")
        XCTAssertThrowsError(try field.validate(["9007199254740993.5"]))
        let text = QuestionField(id: "text", title: "Text", schema: #"{"type":"string","maxLength":1}"#)
        XCTAssertThrowsError(try text.validate(["e\u{0301}"]))
        try text.validate(["я"])
    }

    func testLongMCPMessagesRemainInScrollableContent() throws {
        let message = String(repeating: "Review the requested scope before continuing. ", count: 12)
        let request = try XCTUnwrap(QuestionRequest.elicitation([
            "mode": "url", "message": message, "url": "https://example.com/auth",
        ]))
        XCTAssertEqual(request.question.title, "A tool needs your reply")
        XCTAssertEqual(request.question.detail, message)
    }

    func testMCPURLRequestsAndGrokActionNames() throws {
        let params: [String: Any] = [
            "mode": "url", "message": "Finish in the browser", "url": "https://example.com/auth",
        ]
        let grok = try XCTUnwrap(QuestionRequest.grok("_x.ai/mcp/elicit", params))
        XCTAssertEqual(grok.question.url, "https://example.com/auth")
        XCTAssertTrue(grok.question.fields.isEmpty)
        XCTAssertEqual(grok.response(.init())["outcome"] as? String, "accept")
        XCTAssertEqual(grok.response(.init(action: "cancel"))["outcome"] as? String, "cancel")
        let claude = try XCTUnwrap(QuestionRequest.claude(params.merging(["hook_event_name": "Elicitation"]) { $1 }))
        let response = claude.response(.init(action: "decline"))["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(response?["action"] as? String, "decline")
        XCTAssertEqual(response?["hookEventName"] as? String, "Elicitation")
    }

    func testPersistentPolicyChoicesNameTheirScopeAndReturnTheExactOfferedObject() throws {
        let decisions: [[String: Any]] = [
            ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["echo", "fixture"]]],
            ["applyNetworkPolicyAmendment": [
                "network_policy_amendment": ["action": "deny", "host": "example.com"]
            ]],
        ]
        let request = try XCTUnwrap(QuestionRequest.codex("item/commandExecution/requestApproval", [
            "availableDecisions": decisions
        ]))
        XCTAssertEqual(
            request.question.actions.map(\.label), ["Always Allow: 'echo' 'fixture'", "Always Deny: example.com"])
        let decision = try XCTUnwrap(request.response(.init(action: "1"))["decision"] as? [String: Any])
        XCTAssertEqual(decision as NSDictionary, decisions[1] as NSDictionary)
    }

    func testSecretAnswersReachTheProviderWithoutEnteringTheJournal() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: log) }
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let replied = expectation(description: "native reply preserves the private answer")
        let answer = QuestionAnswer(values: ["token": ["synthetic-private-token"], "note": ["Public note"]])
        let events = RunEvents(session: { _ in }, finished: { _ in }, question: { _, reply in reply(answer) })
        let journal = RunJournal(output: try FileHandle(forWritingTo: log), events: events)
        journal.ask(.init(title: "Credentials", fields: [
            .init(id: "token", title: "Token", kind: .secret), .init(id: "note", title: "Note"),
        ])) { response in
            XCTAssertEqual(response, answer)
            replied.fulfill()
        }
        wait(for: [replied], timeout: 2)
        journal.finish(.succeeded)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(text.contains("synthetic-private-token"))
        XCTAssertTrue(text.contains("[private answer]"))
        XCTAssertTrue(text.contains("Public note"))
    }

    func testExplicitApprovalNeverDefaultsToAllow() throws {
        let request = try XCTUnwrap(
            QuestionRequest.codex(
                "item/commandExecution/requestApproval",
                ["command": "fixture", "availableDecisions": ["accept", "decline"]]))
        XCTAssertEqual(request.response(.init(action: "cancel"))["decision"] as? String, "cancel")
        XCTAssertEqual(request.response(.init(action: "decline"))["decision"] as? String, "decline")
        XCTAssertEqual(request.response(.init(action: "0"))["decision"] as? String, "accept")
        XCTAssertEqual(request.response(.init(action: "1"))["decision"] as? String, "decline")
        XCTAssertNil(QuestionRequest.codex("unknown/method", [:]))
    }
}

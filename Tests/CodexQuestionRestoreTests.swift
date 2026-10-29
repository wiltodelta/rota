import Foundation
@testable import RotaCore
import XCTest

/// A resumed Codex thread replays its whole history, async questions included.
/// Answered ones must stay closed; open ones come back once.
final class CodexQuestionRestoreTests: XCTestCase {
    private final class Asked: @unchecked Sendable {
        var ids: [String] = []
        var resolved: [String] = []
    }

    private func question(_ id: String, _ title: String) -> [String: Any] {
        ["id": id, "type": "agentMessage", "delivery": "async", "text": title,
         "questions": [["title": title, "options": ["Yes", "No"]]]]
    }

    private func user(_ text: String) -> [String: Any] {
        ["id": UUID().uuidString, "type": "userMessage", "content": [["type": "text", "text": text]]]
    }

    private func receipt(_ id: String, _ title: String, action: String = "accept") throws -> String {
        let asked = try XCTUnwrap(QuestionRequest.codexMessage(question(id, title)))
        return QuestionReceipt.message(asked, answer: .init(action: action, values: ["0": ["Yes"]]))
    }

    private func turn(_ id: String, _ items: [[String: Any]], status: String = "completed") -> [String: Any] {
        ["id": id, "status": status, "items": items]
    }

    /// Resumes `thread` over the history `pages`; `during` runs while the first page loads,
    /// `live` once the new turn has started.
    private func resume(prompt: String, pages: [[[String: Any]]], adopt: Bool = false,
                        startFailure: Bool = false,
                        during: ((CodexDaemonRun) -> Void)? = nil, live: ((CodexDaemonRun) -> Void)? = nil,
                        steer: ((CodexDaemonRun, HarnessPeer, [String: Any]) -> Void)? = nil,
                        after: ((CodexDaemonRun) -> Void)? = nil) throws
        -> (asked: [String], started: [String], resolved: [String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let asked = Asked()
        let ended = expectation(description: "run ended")
        let journal = RunJournal(output: try FileHandle(forWritingTo: log), events: RunEvents(
            session: { _ in }, finished: { _ in ended.fulfill() },
            question: { question, _ in asked.ids.append(question.id) },
            questionResolved: { asked.resolved.append($0) }))
        var spec = LaunchSpec(executable: "/bin/false", prompt: prompt, arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .codexDaemon,
                              timeout: nil, log: log, resume: "thread")
        spec.adopt = adopt
        let transport = HarnessPeer()
        let runner = CodexDaemonRun(spec: spec, journal: journal, peer: JSONRPCPeer(transport: transport))
        var page = 0
        var started: [String] = []
        transport.receive = { request in
            let params = request["params"] as? [String: Any] ?? [:]
            switch request["method"] as? String {
            case "initialized": break
            case "thread/resume":
                let active = pages.last?.last?["status"] as? String == "inProgress"
                transport.reply(request, result: ["thread": ["id": "thread",
                                                             "status": ["type": active ? "active" : "idle"]]])
            case "thread/turns/list":
                page += 1
                if page == 1 { during?(runner) }
                var result: [String: Any] = ["data": pages[page - 1]]
                if page < pages.count { result["nextCursor"] = "page-\(page + 1)" }
                transport.reply(request, result: result)
            case "turn/start":
                if startFailure { return transport.reply(request, error: "synthetic start failure") }
                started += (params["input"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                transport.reply(request, result: ["turn": ["id": "new"]])
                live?(runner)
                runner.handle("turn/completed", ["threadId": "thread", "turn": ["id": "new", "status": "completed"]])
            case "turn/steer": steer?(runner, transport, request)
            default: XCTFail("Unexpected request \(request["method"] ?? "unknown")")
            }
        }
        runner.initialized(.success([:]))
        after?(runner)
        wait(for: [ended], timeout: 3)
        return (asked.ids, started, asked.resolved)
    }

    func testAnswerThatContinuesTheThreadKeepsItsQuestionClosed() throws {
        let answer = try receipt("call-1", "Ship it?")
        let first = try resume(prompt: answer, pages: [[turn("t1", [user("start"), question("call-1", "Ship it?")])]])
        XCTAssertEqual(first.asked, [], "the answer being delivered closes its question")
        XCTAssertEqual(first.started, [answer])
        // The next resume finds the answer in the history itself.
        let second = try resume(prompt: "Anything else?", pages: [[
            turn("t1", [user("start"), question("call-1", "Ship it?")]), turn("t2", [user(answer)]),
        ]])
        XCTAssertEqual(second.asked, [])
    }

    func testPagedHistoryReopensOnlyOpenQuestionsOnce() throws {
        let similarJSON = #"{"action":"accept","questions":[{"question":"Second?","answers":["Yes"]}]}"#
        let other = try receipt("call-2", "Second?").replacingOccurrences(of: "call-2", with: "call-other")
        let pages: [[[String: Any]]] = [
            [turn("t1", [question("call-1", "First?"), question("call-2", "Second?"), question("call-3", "Third?"),
                         question("call-4", "Fourth?")])],
            [turn("t2", [user(try receipt("call-1", "First?")),
                         user(try receipt("call-3", "Third?", action: "decline")),
                         user(try receipt("call-4", "Fourth?", action: "cancel"))]),
             turn("t3", [question("call-2", "Second?"), user(similarJSON), user("Answer to your question call-2:\n{"),
                         user("Note: " + (try receipt("call-2", "Second?"))), user(other),
                         user(try receipt("call-2", "Changed title?")),
                         user(try receipt("call-2", "Second?", action: "maybe"))])],
        ]
        let answered = try receipt("call-2", "Second?")
        let result = try resume(prompt: "continue", pages: pages, during: { runner in
            // Live events during the restore: a replayed closed question, an answer
            // from another thread and a new question.
            runner.handle("item/completed", ["threadId": "thread", "item": self.question("call-1", "First?")])
            runner.handle("item/completed", ["threadId": "other", "item": self.user(answered)])
            runner.handle("item/completed", ["threadId": "thread", "item": self.question("call-5", "Fifth?")])
        }, live: { runner in
            // Replayed items after the restore: an open question already shown and a closed one.
            runner.handle("item/completed", ["threadId": "thread", "item": self.question("call-2", "Second?")])
            runner.handle("item/completed", ["threadId": "thread", "item": self.question("call-3", "Third?")])
        })
        XCTAssertEqual(result.asked, ["call-2", "call-5"])
    }

    func testFailedAnswerDeliveryReopensTheQuestionAndADeliveredOneStaysClosed() throws {
        let answer = try receipt("call-1", "Ship it?")
        var steers = 0
        let result = try resume(
            prompt: "original", pages: [[turn("t1", [question("call-1", "Ship it?")], status: "inProgress")]],
            adopt: true,
            steer: { runner, transport, request in
                steers += 1
                guard steers > 1 else { return transport.reply(request, error: "synthetic steer failure") }
                transport.reply(request)
                runner.handle("item/completed", ["threadId": "thread", "item": self.user(answer)])
                runner.handle("item/completed", ["threadId": "thread", "item": self.question("call-1", "Ship it?")])
                runner.handle("turn/completed", ["threadId": "thread", "turn": ["id": "t1", "status": "completed"]])
            },
            after: { runner in
                runner.send(answer)
                runner.send(answer)
            })
        XCTAssertEqual(steers, 2)
        XCTAssertEqual(result.asked, ["call-1", "call-1"], "only the undelivered answer reopens the question")
    }

    func testDeferredCompletionStillRestoresOpenQuestions() throws {
        let result = try resume(prompt: "unused", pages: [[
            turn("t1", [question("open", "Still open?")], status: "inProgress"),
        ]], adopt: true, during: { runner in
            runner.handle("turn/completed", ["threadId": "thread", "turn": ["id": "t1", "status": "completed"]])
        })
        XCTAssertEqual(result.asked, ["open"])
    }

    func testDeferredAnswerClosesBeforePublishingAndLiveAnswerResolvesPending() throws {
        let answer = try receipt("call-1", "Ship it?")
        let held = try resume(prompt: "continue", pages: [[turn("t1", [question("call-1", "Ship it?")])]],
                              during: { runner in
            runner.handle("item/completed", ["threadId": "thread", "item": self.user(answer)])
            runner.handle("item/completed", ["threadId": "thread", "item": self.question("call-1", "Ship it?")])
        })
        XCTAssertEqual(held.asked, [])
        let live = try resume(prompt: "continue", pages: [[turn("t1", [question("call-1", "Ship it?")])]],
                              live: { runner in
            runner.handle("item/completed", ["threadId": "thread", "item": self.user(answer)])
            runner.handle("item/completed", ["threadId": "thread", "item": self.question("call-1", "Ship it?")])
        })
        XCTAssertEqual(live.asked, ["call-1"])
        XCTAssertTrue(live.resolved.contains("call-1"))
    }

    func testFailedContinuationRestoresTheAnsweredCardForRetry() throws {
        let result = try resume(prompt: receipt("call-1", "Ship it?"),
                                pages: [[turn("t1", [question("call-1", "Ship it?")])]], startFailure: true)
        XCTAssertEqual(result.asked, ["call-1"])
    }

    func testFailedDuplicateCannotEraseAConfirmedAnswer() throws {
        let answer = try receipt("call-1", "Ship it?")
        var state = CodexAsyncQuestions()
        let card = try XCTUnwrap(QuestionRequest.codexMessage(question("call-1", "Ship it?")))
        state.noteAnswer(answer)
        state.sending(answer)
        XCTAssertNil(state.undelivered(answer))
        XCTAssertNil(state.offer(card))
    }

    func testInvalidAnswerValuesAndNonTextContentDoNotCloseQuestions() throws {
        let answer = try receipt("call-1", "Ship it?")
        let empty = answer.replacingOccurrences(of: "Yes", with: "")
        let result = try resume(prompt: "continue", pages: [[turn("t1", [
            question("call-1", "Ship it?"), user(empty),
            ["type": "userMessage", "content": [["type": "image", "text": answer]]],
            ["type": "agentMessage", "text": answer],
        ])]])
        XCTAssertEqual(result.asked, ["call-1"])
    }

    func testOnlyFinishedRotaReceiptsAnswerAQuestion() throws {
        for action in ["accept", "decline", "cancel"] {
            XCTAssertEqual(QuestionReceipt.answer(try receipt("call-1", "Ship it?", action: action))?.id, "call-1")
        }
        XCTAssertNil(QuestionReceipt.answer(try receipt("call-1", "Ship it?", action: "maybe")))
        XCTAssertNil(QuestionReceipt.answer("Answer to your question call-1:\nnot json"))
        XCTAssertNil(QuestionReceipt.answer(#"{"action":"accept","questions":[]}"#))
        XCTAssertNil(QuestionReceipt.answer("Re: " + (try receipt("call-1", "Ship it?"))))
    }
}

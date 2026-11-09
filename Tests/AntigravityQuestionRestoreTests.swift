import XCTest

@testable import RotaCore

@MainActor
final class AntigravityQuestionRestoreTests: XCTestCase {
    private final class NoLauncher: RoutineLaunching {
        func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
            XCTFail("Restoring a question must not launch the agent")
            throw ControlError("Unexpected launch")
        }
    }

    func testSavedFallbackIsRepairedWithoutReopeningAnsweredQuestionsOrChangingActivity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rota-question-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = StorageLocation(root: root, logs: root.appendingPathComponent("Logs"))
        let scheduler = Scheduler(location: location, launcher: NoLauncher())
        let routine = Routine(id: "fixture", name: "Fixture", workingDirectory: root.path,
                              schedule: "0 10 * * *", harness: .antigravity, prompt: "Fixture")
        scheduler.save(routine)
        let session = "00000000-0000-4000-8000-000000000001"
        let id = "antigravity/\(session)/1/0"
        var fallback = try XCTUnwrap(QuestionRequest.antigravity("ask_question", arguments: [:], id: id))
        fallback.title = "A historical fallback title"
        let permission = try XCTUnwrap(QuestionRequest.antigravity("ask_permission", arguments: [:], id: "permission"))
        var record = RunRecord(routineID: routine.id, trigger: .manual, harness: .antigravity,
                               startedAt: Date(timeIntervalSince1970: 100), outcome: .succeeded)
        record.sessionID = session
        record.questions = [fallback, permission]
        record.attention = fallback.title
        scheduler.saveRecord(record)
        let home = root.appendingPathComponent("native-home")
        let archive = try XCTUnwrap(AntigravityQuestionArchive(session: session, home: home))
        scheduler.restoreAntigravityQuestions(home: home)
        XCTAssertEqual(scheduler.current(record.id)?.questions, record.questions, "Missing metadata preserves the card")
        try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let row: [String: Any] = [
            "type": "PLANNER_RESPONSE", "status": "DONE", "step_index": 1,
            "tool_calls": [["name": "ask_question", "args": ["questions": [
                ["question": "Color?", "options": ["Blue", "Green"]],
            ]]]],
        ]
        let full = archive.file.deletingLastPathComponent().appendingPathComponent("transcript_full.jsonl")
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: full)
        scheduler.restoreAntigravityQuestions(home: home)
        let repaired = try XCTUnwrap(scheduler.current(record.id))
        XCTAssertEqual(repaired.questions?.first?.fields.first?.title, "Color?")
        XCTAssertEqual(repaired.questions?.last, permission)
        XCTAssertEqual(repaired.questions?.count, 2)
        XCTAssertEqual(repaired.lastActivityAt, record.lastActivityAt)
        XCTAssertEqual(repaired.attention, "Antigravity needs your reply")
        XCTAssertEqual(scheduler.history.records(for: routine.id).first?.questions, repaired.questions)

        scheduler.active[record.id] = record
        scheduler.restoreAntigravityQuestions(home: home)
        XCTAssertEqual(scheduler.active[record.id]?.questions, repaired.questions,
                       "The active snapshot must not overwrite the repair when the run ends")
        scheduler.active.removeValue(forKey: record.id)

        record.questions = [permission]
        scheduler.saveRecord(record)
        scheduler.restoreAntigravityQuestions(home: home)
        XCTAssertEqual(scheduler.current(record.id)?.questions, [permission], "Answered calls must stay answered")
    }
}

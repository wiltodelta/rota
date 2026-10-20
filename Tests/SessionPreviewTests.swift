@testable import RotaCore
import XCTest

final class SessionPreviewTests: XCTestCase {
    private func record(_ outcome: RunOutcome = .succeeded) -> RunRecord {
        RunRecord(routineID: "preview-check", trigger: .manual, harness: .codex,
                  startedAt: Date(), outcome: outcome)
    }

    func testLatestAnswerExcludesPromptToolsAndFinishMetadata() {
        let snapshot = TranscriptSnapshot(items: Transcript.parse("""
        [you] An instruction that must not become the preview.
        Earlier commentary
        -> Read project files
        ## Result
        **Проверка завершена.** [Details](https://example.com)
        [result: Succeeded after 20 s]
        """))
        XCTAssertEqual(SessionPreview.text(for: record(), snapshot: snapshot), "Result Проверка завершена. Details")
        let awaitingReply = TranscriptSnapshot(items: snapshot.items + [
            .init(id: 99, kind: .user, text: "A new private follow-up")
        ])
        XCTAssertEqual(SessionPreview.text(for: record(.running), snapshot: awaitingReply),
                       "Result Проверка завершена. Details")
    }

    func testQuestionsOverrideEarlierSuccessAndPrivateInputIsNeverUsed() {
        var run = record(.running)
        run.questions = [.init(title: "A tool needs your reply", fields: [.init(id: "choice", title: "Which folder?")])]
        let snapshot = TranscriptSnapshot(items: [.init(id: 0, kind: .user, text: "private answer")])
        XCTAssertEqual(SessionPreview.text(for: run, snapshot: snapshot), "Which folder?")
        run.questions = nil
        run.attention = "Please sign in to continue."
        XCTAssertEqual(SessionPreview.text(for: run, snapshot: snapshot), "Please sign in to continue.")
    }

    func testFailureShowsReasonAndMissingContentDoesNotInventSuccess() {
        let snapshot = TranscriptSnapshot(items: [
            .init(id: 0, kind: .error, text: "Access denied"),
            .init(id: 1, kind: .agent, text: "Earlier result")
        ])
        XCTAssertEqual(SessionPreview.text(for: record(.failed(exitCode: 1)), snapshot: snapshot), "Access denied")
        XCTAssertEqual(SessionPreview.text(for: record(.launchFailed("Binary missing")), snapshot: nil),
                       "Binary missing")
        XCTAssertEqual(SessionPreview.text(for: record(), snapshot: .init()), "No agent message.")
        XCTAssertTrue(SessionPreview.text(for: record(), snapshot: .init(problem: "missing")).contains("Couldn't read"))
    }

    func testRunningToolsDoNotReplaceTheLatestReadableMessage() {
        let items = Transcript.parse("[you] Check\nAn update\n-> Inspect deployment")
        for outcome in [RunOutcome.running, .succeeded, .cancelled, .failed(exitCode: 1)] {
            XCTAssertEqual(SessionPreview.text(for: record(outcome), snapshot: .init(items: items)), "An update")
        }
        let toolsOnly = TranscriptSnapshot(items: [.init(id: 0, kind: .tool, text: "Inspect deployment")])
        XCTAssertEqual(SessionPreview.text(for: record(.running), snapshot: toolsOnly),
                       "Waiting for the first message…")
    }

    func testShellOutputRemainsReadable() {
        var run = record()
        run.harness = .shell
        XCTAssertEqual(SessionPreview.text(for: run, snapshot: .init(items: Transcript.parse(
            "[you] command\nFirst line\nLast line\n[result: Succeeded after 2 s]", shell: true))),
                       "First line Last line")
    }

    func testAgentToolOutputDoesNotReplaceTheReadableMessage() {
        var run = record(.running)
        run.harness = .antigravity
        let snapshot = TranscriptSnapshot(items: [
            .init(id: 0, kind: .agent, text: "The checks are complete."),
            .init(id: 1, kind: .output, text: #"{"internal_tool_result":true}"#),
        ])
        XCTAssertEqual(SessionPreview.text(for: run, snapshot: snapshot), "The checks are complete.")
    }

    func testPreviewReadsTheRealJournalAndRemainsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let transcript = try TranscriptJournal(log: log, resuming: false, logSize: 0)
        let journal = RunJournal(output: output, events: RunEvents(session: { _ in }, finished: { _ in }),
                                 transcript: transcript)
        journal.record(.user, "Never show this instruction")
        journal.text("Final answer ")
        journal.text(String(repeating: "long content ", count: 500))
        journal.endText()
        journal.record(.tool, "Read deployment configuration")
        let reader = TranscriptSessionReader()
        let snapshot = await reader.read(log: log, shell: false, finished: false)
        XCTAssertTrue(snapshot.structured)
        let preview = SessionPreview.text(for: record(.running), snapshot: snapshot)
        XCTAssertTrue(preview.hasPrefix("Final answer"))
        XCTAssertLessThanOrEqual(preview.count, 320)
    }
}

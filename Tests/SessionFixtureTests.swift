@testable import RotaCore
import XCTest

/// Uses the shipping event producer to render a synthetic conversation without launching an agent.
final class SessionFixtureTests: XCTestCase {
    func testCreateSyntheticConversation() throws {
        let requested = ProcessInfo.processInfo.environment["ROTA_CHAT_FIXTURE_DIR"]
        let folder = requested.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if requested == nil { try? FileManager.default.removeItem(at: folder) } }
        let location = StorageLocation(root: folder, logs: folder.appendingPathComponent("Logs"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.routinesFile.path))
        guard !FileManager.default.fileExists(atPath: location.routinesFile.path) else { return }
        let routine = Routine(id: "chat-preview", name: "Chat preview", workingDirectory: folder.path,
                              schedule: "0 9 * * *", harness: .codex, prompt: "Review the sample report.")
        try RoutineStore(location: location).save([routine])
        let history = RunHistory(location: location)
        var record = RunRecord(routineID: routine.id, trigger: .manual, harness: .codex,
                               startedAt: Date(), endedAt: Date(), outcome: .succeeded)
        let log = history.logFile(for: record)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let spec = LaunchSpec(executable: "/bin/echo", prompt: routine.prompt, arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .codexDaemon, timeout: nil,
                              log: log, model: "example-model-v1", effort: "high")
        let journal = try RunJournal(output: FileHandle(forWritingTo: log),
                                     events: RunEvents(session: { _ in }, finished: { _ in }), spec: spec, legacy: nil)
        journal.delivery(spec.messageID, .accepted)
        journal.metadata(model: "example-model-v1", effort: "high")
        journal.event(.assistant(id: "commentary", text: "Checking the sample report and its totals.", phase: .work))
        journal.event(.tool(id: "tool-1", title: "Read sample.txt", input: #"{"path":"sample.txt"}"#,
                            output: "The sample report contains three completed tasks.", status: "completed"))
        journal.event(.plan([PlanStep(status: .completed, text: "Read the report"),
                             PlanStep(status: .completed, text: "Verify the totals")]))
        journal.event(.assistant(id: "answer",
                                 text: "The totals match.\n\n- Three tasks completed\n- No missing entries",
                                 phase: .answer))
        let files = try AttachmentTestFixture.create(in: folder.appendingPathComponent("synthetic-attachments"))
        let attachmentMessage = ChatMessage(text: "Also check the archived report. Привет 𠀀",
                                            attachments: try files.files.map(ChatAttachment.inspect))
        let retained = try ChatAttachmentStore.retain(attachmentMessage, log: log, messageID: "follow-up")
        journal.user(retained, id: "follow-up")
        journal.delivery("follow-up", .failed("The active turn ended before the message was accepted."))
        journal.finish(.succeeded)
        record.logPath = log.path
        record.sessionID = "synthetic-provider-session"
        record.configuration = RunConfiguration(model: "example-model-v1", effort: "high",
                                                workingDirectory: folder.path)
        record.metadata = SessionMetadata(model: "example-model-v1", effort: "high")
        try history.upsert(record)
        let reader = SessionEventReader()
        XCTAssertTrue(try reader.read(from: SessionEventReader.file(for: log)))
        XCTAssertEqual(reader.transcript.items.last(where: { $0.kind == .user })?.delivery,
                       .failed("The active turn ended before the message was accepted."))
    }
}

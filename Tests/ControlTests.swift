@testable import RotaCore
import XCTest

@MainActor
final class ControlCommandTests: XCTestCase {
    private var directory: URL!
    private var scheduler: Scheduler!
    private var launcher: ControlFakeLauncher!
    private var notifier: AddedNotifier!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        launcher = ControlFakeLauncher()
        notifier = AddedNotifier()
        scheduler = Scheduler(location: StorageLocation(root: directory,
                                                   logs: directory.appendingPathComponent("logs")),
                              launcher: launcher)
        scheduler.executable = { "/bin/\($0.rawValue)" }
        scheduler.notifier = notifier
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) -> Result<Any, ControlError> {
        scheduler.control(method, params)
    }

    private func create(_ extra: [String: Any] = [:]) -> Result<Any, ControlError> {
        call("routines.create", ["id": "digest", "workingDirectory": directory.path, "schedule": "0 9 * * 1-5",
                                 "harness": "codex", "prompt": "Summarize."].merging(extra) { $1 })
    }

    func testAnAgentCreatesARoutineThatRunsOnItsSchedule() throws {
        let created = try create(["model": "gpt-6-sol"]).get() as? [String: Any]
        XCTAssertEqual(created?["scheduleText"] as? String, ScheduleText.describe("0 9 * * 1-5"))
        let routine = try XCTUnwrap(scheduler.routine("digest"))
        XCTAssertTrue(routine.enabled)
        XCTAssertNotNil(routine.nextFire)
        XCTAssertEqual(routine.harness, .codex)
        XCTAssertEqual(routine.model, "gpt-6-sol")
        XCTAssertEqual(notifier.added, ["digest"])
        XCTAssertEqual(try XCTUnwrap(try call("routines.list").get() as? [[String: Any]]).count, 1)
    }

    func testCreateRefusesWhatCouldNotRun() {
        let missing = create(["workingDirectory": "/nonexistent-rota"])
        XCTAssertEqual(missing.failure?.message.contains("does not exist"), true)
        XCTAssertEqual(create(["schedule": "every day"]).failure?.message.contains("schedule"), true)
        XCTAssertEqual(create(["id": "Bad Id"]).failure?.message.contains("lowercase"), true)
        XCTAssertEqual(create(["prompt": "  "]).failure?.message.contains("prompt"), true)
        XCTAssertEqual(create(["harness": "gemini"]).failure?.message.contains("Unknown harness"), true)
        XCTAssertEqual(create(["timeLimitMinutes": "ten"]).failure?.message.contains("a number"), true)
        XCTAssertNil(scheduler.routine("digest"))
        XCTAssertEqual(notifier.added, [])
        _ = create()
        XCTAssertEqual(create().failure?.message.contains("exists"), true)
    }

    /// The window's sheets ask the same question, so what the API refuses never saves from the window.
    func testTheWindowSharesTheValidation() throws {
        var routine = Routine(id: "", name: "", workingDirectory: directory.path, schedule: "0 9 * * *",
                              harness: .shell, prompt: "echo hi")
        XCTAssertEqual(routine.problem(), "Give the routine an id, such as weekly-report.")
        routine.id = "Imported Task"
        XCTAssertEqual(routine.problem()?.contains("lowercase"), true)
        XCTAssertNil(routine.problem(checkingID: false), "an existing routine keeps the id it came with")
        routine.id = "backup"
        XCTAssertNil(routine.problem())
        routine.prompt = " "
        XCTAssertEqual(routine.problem(), "Give the command.")
        routine.prompt = "echo hi"
        routine.workingDirectory = ""
        XCTAssertEqual(routine.problem(), "Choose the project folder.")
        routine.workingDirectory = directory.appendingPathComponent("missing").path
        XCTAssertEqual(routine.problem()?.contains("does not exist"), true)
        XCTAssertFalse(Routine.isValidID("caf\u{E9}"), "an id is ASCII: it names a file")
    }

    func testUpdateKeepsAnImportedID() throws {
        let imported = Routine(id: "Imported Task", name: "Imported", workingDirectory: directory.path,
                               schedule: "0 9 * * *", harness: .shell, enabled: false, prompt: "echo hi")
        scheduler.save(imported)
        _ = try call("routines.update", ["id": "Imported Task", "schedule": "0 10 * * *"]).get()
        XCTAssertEqual(scheduler.routine("Imported Task")?.schedule, "0 10 * * *")
    }

    func testCreateCanStartOffAndTakeASkill() throws {
        _ = try create(["enabled": false, "prompt": NSNull(), "skill": "weekly-seo"]).get()
        let routine = try XCTUnwrap(scheduler.routine("digest"))
        XCTAssertFalse(routine.enabled)
        XCTAssertNil(routine.nextFire)
        XCTAssertEqual(routine.prompt, Routine.defaultPrompt(skill: "weekly-seo", workingDirectory: directory.path))
    }

    func testUpdateChangesOnlyTheGivenFieldsAndDropsAModelOfAnotherHarness() throws {
        _ = try create(["model": "gpt-6-sol", "effort": "high", "timeLimitMinutes": 30]).get()
        _ = try call("routines.update", ["id": "digest", "schedule": "30 7 * * *"]).get()
        var routine = try XCTUnwrap(scheduler.routine("digest"))
        XCTAssertEqual(routine.schedule, "30 7 * * *")
        XCTAssertEqual(routine.prompt, "Summarize.")
        XCTAssertEqual(routine.model, "gpt-6-sol")
        _ = try call("routines.update", ["id": "digest", "harness": "claude", "timeLimitMinutes": NSNull()]).get()
        routine = try XCTUnwrap(scheduler.routine("digest"))
        XCTAssertEqual(routine.harness, .claude)
        XCTAssertNil(routine.model)
        XCTAssertNil(routine.effort)
        XCTAssertNil(routine.timeLimitMinutes)
        XCTAssertEqual(call("routines.update", ["id": "nope"]).failure?.message, "No routine nope.")
    }

    /// Claude runs interactively where the setting is on and Claude Code trusts the folder, else as claude -p.
    func testClaudeRunsInteractivelyOnlyInATrustedFolder() throws {
        _ = try create(["harness": "claude"]).get()
        scheduler.claudeInteractive = { true }
        scheduler.claudeSettings = { ClaudeUserSettings(trustedProjects: [self.directory.path]) }
        _ = try call("routines.run", ["id": "digest"]).get()
        XCTAssertEqual(launcher.specs.last?.mode, .claudeInteractive)
        XCTAssertNil(launcher.specs.last?.notice)
        _ = try call("routines.stop", ["id": "digest"]).get()
        launcher.events.last?.finished(.cancelled)

        scheduler.claudeSettings = { ClaudeUserSettings() }
        _ = try call("routines.run", ["id": "digest"]).get()
        XCTAssertEqual(launcher.specs.last?.mode, .claudeStream)
        XCTAssertEqual(launcher.specs.last?.notice?.contains("not been trusted"), true)
        launcher.events.last?.finished(.succeeded)

        scheduler.claudeInteractive = { false }
        scheduler.claudeSettings = { ClaudeUserSettings(trustedProjects: [self.directory.path]) }
        _ = try call("routines.run", ["id": "digest"]).get()
        XCTAssertEqual(launcher.specs.last?.mode, .claudeStream)
        XCTAssertNil(launcher.specs.last?.notice)
    }

    func testRunStopEnableAndDelete() throws {
        _ = try create().get()
        let run = try XCTUnwrap(try call("routines.run", ["id": "digest"]).get() as? [String: Any])
        XCTAssertEqual(run["running"] as? Bool, true)
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(call("routines.run", ["id": "digest"]).failure?.message, "digest is already running.")
        _ = try call("routines.stop", ["id": "digest"]).get()
        XCTAssertTrue(launcher.controls[0].stopped)
        _ = try call("routines.setEnabled", ["id": "digest", "enabled": false]).get()
        XCTAssertEqual(scheduler.routine("digest")?.enabled, false)
        XCTAssertEqual(call("routines.setEnabled", ["id": "digest"]).failure?.message, "Missing enabled.")
        _ = try call("routines.delete", ["id": "digest"]).get()
        XCTAssertNil(scheduler.routine("digest"))
    }

    func testSessionsReadAndContinue() throws {
        _ = try create().get()
        _ = try call("routines.run", ["id": "digest"]).get()
        launcher.events[0].session("thread-1")
        let log = try XCTUnwrap(launcher.specs.first?.log)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[you] Summarize.\nAll quiet.\n".write(to: log, atomically: true, encoding: .utf8)
        launcher.events[0].finished(.succeeded)
        let sessions = try XCTUnwrap(try call("sessions.list", ["id": "digest"]).get() as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        let read = try XCTUnwrap(try call("sessions.read", ["id": "digest", "limit": 11]).get() as? [String: Any])
        XCTAssertEqual(read["log"] as? String, "All quiet.\n")
        XCTAssertEqual(read["truncated"] as? Bool, true)
        _ = try call("sessions.message", ["id": "digest", "text": "And yesterday?"]).get()
        XCTAssertEqual(launcher.specs.last?.resume, "thread-1")
        XCTAssertEqual(launcher.specs.last?.prompt, "And yesterday?")
        XCTAssertEqual(call("sessions.read", ["id": "digest", "session": "nope"]).failure?.message,
                       "No session nope of digest.")
    }

    func testEachRunKnowsItsSessionAndTheCommand() throws {
        scheduler.commandPath = "/Applications/Rota.app/Contents/Helpers/rota"
        _ = try create().get()
        _ = try call("routines.run", ["id": "digest"]).get()
        let spec = try XCTUnwrap(launcher.specs.first)
        let record = try XCTUnwrap(scheduler.active["digest"])
        XCTAssertEqual(spec.environment["ROTA_SESSION"], record.id.uuidString)
        XCTAssertEqual(spec.environment["ROTA_ROUTINE"], "digest")
        XCTAssertEqual(spec.environment["ROTA_CLI"], "/Applications/Rota.app/Contents/Helpers/rota")
    }

    func testASessionAsksForAReplyUntilTheUserAnswers() throws {
        _ = try create().get()
        _ = try call("routines.run", ["id": "digest"]).get()
        launcher.events[0].session("thread-1")
        let session = try XCTUnwrap(scheduler.active["digest"]).id.uuidString
        _ = try call("notify", ["message": "Approve the invoice?", "session": session, "needsReply": true]).get()
        XCTAssertEqual(scheduler.active["digest"]?.attention, "Approve the invoice?")
        XCTAssertEqual(notifier.notified.last?.session?.uuidString, session)
        XCTAssertEqual(notifier.notified.last?.needsReply, true)
        // The mark outlives the run, and answering clears it.
        launcher.events[0].finished(.succeeded)
        var record = try XCTUnwrap(scheduler.history.records(for: "digest").first)
        XCTAssertEqual(record.attention, "Approve the invoice?")
        XCTAssertEqual(scheduler.attentionCount, 1)
        scheduler.message("Yes, approve it.", to: record)
        XCTAssertNil(try XCTUnwrap(scheduler.history.records(for: "digest").first).attention)
        // Dismissing clears it without a reply.
        launcher.events[1].finished(.succeeded)
        record = try XCTUnwrap(scheduler.history.records(for: "digest").first)
        _ = try call("notify", ["message": "Again?", "routine": "digest", "needsReply": true]).get()
        _ = try call("sessions.dismiss", ["id": "digest"]).get()
        XCTAssertEqual(scheduler.attentionCount, 0)
        XCTAssertEqual(record.id, try XCTUnwrap(scheduler.history.records(for: "digest").first).id)
    }

    func testANotificationFromOutsideARoutineHasNoSession() throws {
        _ = try call("notify", ["message": "Build finished."]).get()
        XCTAssertNil(notifier.notified.last?.session)
        XCTAssertEqual(call("notify", ["message": "Answer me", "needsReply": true]).failure?.message
            .contains("must come from a session"), true)
        XCTAssertEqual(call("notify", ["message": "x", "session": "nope"]).failure?.message, "No session nope.")
        XCTAssertEqual(call("notify", ["message": " "]).failure?.message, "The notification needs a message.")
    }

    func testSessionStateAndReadMarkUseTheRunSnapshot() throws {
        _ = try create(["model": "chosen-model", "effort": "high"]).get()
        _ = try call("routines.run", ["id": "digest"]).get()
        launcher.events[0].session("native-thread")
        launcher.events[0].configuration(SessionConfiguration(model: "reported-model", effort: "low"))
        launcher.events[0].finished(.succeeded)
        _ = try call("routines.update", ["id": "digest", "model": "new-model"]).get()
        let state = try XCTUnwrap(try call("sessions.get", ["id": "digest"]).get() as? [String: Any])
        XCTAssertEqual(state["model"] as? String, "reported-model")
        XCTAssertEqual(state["effort"] as? String, "low")
        XCTAssertEqual(state["unread"] as? Bool, true)
        XCTAssertEqual(state["canDelete"] as? Bool, true)
        let read = try XCTUnwrap(try call("sessions.markRead", ["id": "digest"]).get() as? [String: Any])
        XCTAssertEqual(read["unread"] as? Bool, false)
        XCTAssertEqual(scheduler.unreadCount, 0)
    }

    func testDeletionRequiresAnExplicitFinishedSessionAndRemovesItsFiles() throws {
        _ = try create().get()
        _ = try call("routines.run", ["id": "digest"]).get()
        let record = try XCTUnwrap(scheduler.active["digest"])
        let params: [String: Any] = ["id": "digest", "session": record.id.uuidString]
        XCTAssertNotNil(call("sessions.delete", ["id": "digest"]).failure)
        XCTAssertNotNil(call("sessions.delete", params).failure)
        XCTAssertNotNil(scheduler.current(record.id))
        let log = try XCTUnwrap(launcher.specs.first?.log)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Synthetic log".write(to: log, atomically: true, encoding: .utf8)
        launcher.events[0].finished(.succeeded)
        _ = try call("sessions.delete", params).get()
        XCTAssertNil(scheduler.current(record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertNotNil(scheduler.routine("digest"))
    }

    func testQuestionsRequireExplicitValidatedAnswersAndCannotBeDismissed() throws {
        _ = try create().get()
        _ = try call("routines.run", ["id": "digest"]).get()
        launcher.events[0].session("native-thread")
        let question = AgentQuestion(id: "decision", title: "Choose a target", fields: [
            QuestionField(id: "target", title: "Target", kind: .choice,
                          options: [.init(id: "staging", label: "Staging")], allowsOther: false)
        ])
        nonisolated(unsafe) var answers: [QuestionAnswer] = []
        launcher.events[0].question(question) { answers.append($0) }
        let pending = try XCTUnwrap(try call("sessions.questions", ["id": "digest"]).get() as? [[String: Any]])
        XCTAssertEqual(pending.first?["id"] as? String, "decision")
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotNil(call("sessions.dismiss", ["id": "digest"]).failure)
        XCTAssertNotNil(call("sessions.message", ["id": "digest", "text": "yes"]).failure)
        var params: [String: Any] = ["id": "digest", "question": "decision"]
        XCTAssertNotNil(call("sessions.answer", params).failure)
        params["action"] = "accept"
        params["values"] = ["target": ["production"]]
        XCTAssertNotNil(call("sessions.answer", params).failure)
        XCTAssertTrue(answers.isEmpty)
        XCTAssertEqual(scheduler.active["digest"]?.questions?.count, 1)
        params["values"] = ["target": ["staging"]]
        _ = try call("sessions.answer", params).get()
        XCTAssertEqual(answers, [.init(values: ["target": ["staging"]])])
        XCTAssertEqual(scheduler.active["digest"]?.questions?.count, 0)
        XCTAssertNil(scheduler.active["digest"]?.attention)
        XCTAssertNotNil(call("sessions.answer", params).failure)
    }

    func testAttachmentsAreCopiedAndSentThroughTheRealMessageSeam() async throws {
        _ = try create().get()
        _ = try call("routines.run", ["id": "digest"]).get()
        launcher.events[0].session("native-thread")
        let source = directory.appendingPathComponent("synthetic.txt")
        try "Synthetic attachment".write(to: source, atomically: true, encoding: .utf8)
        let result = await scheduler.controlRequest("sessions.message",
                                                    ["id": "digest", "text": "", "attachments": [source.path]])
        _ = try result.get()
        let message = ChatMessage.decode(try XCTUnwrap(launcher.controls[0].messages.first))
        XCTAssertEqual(message.attachments.count, 1)
        let copy = try XCTUnwrap(message.attachments.first)
        XCTAssertNotEqual(copy.path, source.path)
        XCTAssertEqual(try String(contentsOf: copy.url, encoding: .utf8), "Synthetic attachment")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNotNil(call("sessions.message", ["id": "digest", "text": "", "attachments": ["relative.txt"]]).failure)
        XCTAssertNotNil(call("sessions.message", ["id": "digest", "text": "", "attachments": 1]).failure)
        XCTAssertEqual(launcher.controls[0].messages.count, 1)
    }

    func testRejectedContinuationDiscardsStagedCopiesAndReportsFailure() async throws {
        _ = try create().get()
        _ = try call("routines.run", ["id": "digest"]).get()
        launcher.events[0].session("native-thread")
        launcher.events[0].finished(.succeeded)
        let record = try XCTUnwrap(scheduler.history.records(for: "digest").first)
        let store = try scheduler.history.attachments(for: record)
        let source = directory.appendingPathComponent("synthetic.txt")
        try "Synthetic attachment".write(to: source, atomically: true, encoding: .utf8)
        launcher.failLaunch = true
        let result = await scheduler.controlRequest("sessions.message", [
            "id": "digest", "session": record.id.uuidString, "text": "", "attachments": [source.path]
        ])
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(launcher.specs.count, 2, "the continuation reached the actual launcher")
        let staged = try FileManager.default.contentsOfDirectory(at: store.folder, includingPropertiesForKeys: nil)
        XCTAssertTrue(staged.isEmpty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Synthetic attachment")
    }

    func testEveryDeclaredOperationReachesAHandler() {
        for method in ControlMethod.allCases {
            let error = call(method.rawValue).failure?.message ?? ""
            XCTAssertFalse(error.contains("Unknown method"), method.rawValue)
            XCTAssertFalse(error.contains("Unknown question method"), method.rawValue)
        }
    }

    func testUnknownMethodNamesTheKnownOnes() {
        XCTAssertEqual(call("routines.explode").failure?.message.contains("routines.list"), true)
    }
}

final class ControlSocketTests: XCTestCase {
    /// A short path: a Unix socket's path must fit in 104 bytes.
    private func socketPath() -> URL {
        URL(fileURLWithPath: "/tmp/rota-test-\(UUID().uuidString.prefix(8)).sock")
    }

    func testARequestCrossesTheSocketAndComesBack() throws {
        let path = socketPath()
        let server = ControlServer(socket: path) { method, params in
            method == "echo" ? .success(["got": params["text"] ?? NSNull()]) : .failure(ControlError("nope"))
        }
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "only the user may reach the socket")
        let reply = expectation(description: "reply")
        // The handler runs on the main queue, so the client waits on another one.
        nonisolated(unsafe) var echoed: String?
        nonisolated(unsafe) var refusal: String?
        DispatchQueue.global().async {
            let answer = try? ControlClient.call("echo", ["text": "hi"], socket: path, timeout: 5)
            echoed = (answer as? [String: Any])?["got"]
                as? String
            do {
                _ = try ControlClient.call("other", socket: path, timeout: 5)
            } catch {
                refusal = (error as? ControlError)?.message
            }
            reply.fulfill()
        }
        wait(for: [reply], timeout: 10)
        XCTAssertEqual(echoed, "hi")
        XCTAssertEqual(refusal, "nope")
    }

    func testNoAppOnTheSocketReadsAsNotRunning() {
        XCTAssertThrowsError(try ControlClient.call("routines.list", socket: socketPath(), timeout: 2)) { error in
            XCTAssertEqual(error as? ControlError, .notRunning)
        }
    }
}

private final class ControlFakeControl: RunControl {
    var stopped = false
    var messages: [String] = []
    func send(_ message: String) { messages.append(message) }
    func stop() { stopped = true }
}

private final class ControlFakeLauncher: RoutineLaunching {
    var specs: [LaunchSpec] = []
    var failLaunch = false
    var events: [RunEvents] = []
    var controls: [ControlFakeControl] = []
    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        specs.append(spec)
        if failLaunch { throw ControlError("Synthetic launch failure.") }
        self.events.append(events)
        let control = ControlFakeControl()
        controls.append(control)
        return control
    }
}

private final class AddedNotifier: RunNotifying {
    var added: [String] = []
    var notified: [(session: UUID?, text: String, needsReply: Bool)] = []
    func sessionNotified(_ record: RunRecord?, routine: Routine?, title: String?, text: String, needsReply: Bool) {
        notified.append((record?.id, text, needsReply))
    }
    func runEnded(_ record: RunRecord, routine: Routine) {}
    func routinePaused(_ routine: Routine, failures: Int) {}
    func routineAdded(_ routine: Routine) { added.append(routine.id) }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

final class AgentAccessTests: XCTestCase {
    func testEachAgentCLIGetsItsOwnAddAndRemoveArguments() {
        XCTAssertEqual(AgentAccess.addArguments(.claude, command: "/r"),
                       ["mcp", "add", "-s", "user", "rota", "--", "/r", "mcp"])
        XCTAssertEqual(AgentAccess.addArguments(.codex, command: "/r"), ["mcp", "add", "rota", "--", "/r", "mcp"])
        XCTAssertEqual(AgentAccess.addArguments(.grok, command: "/r"),
                       ["mcp", "add", "-s", "user", "rota", "/r", "--", "mcp"])
        XCTAssertEqual(AgentAccess.removeArguments(.codex), ["mcp", "remove", "rota"])
        XCTAssertEqual(AgentAccess.addArguments(.shell, command: "/r"), [])
    }

    func testAJSONListingNamesTheServer() {
        XCTAssertTrue(AgentAccess.lists("rota", in: #"{"servers":[{"name":"rota","command":"/r"}]}"#))
        XCTAssertTrue(AgentAccess.lists("rota", in: #"{"rota":{"command":"/r"}}"#))
        XCTAssertFalse(AgentAccess.lists("rota", in: #"{"servers":[{"name":"rotary"}]}"#))
        XCTAssertFalse(AgentAccess.lists("rota", in: "No MCP servers configured."))
    }

    func testInstallingTheCommandLinksItAndNeverReplacesAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("Rota.app/Contents/Helpers/rota")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: helper)
        let link = folder.appendingPathComponent("bin/rota")
        XCTAssertFalse(AgentAccess.commandInstalled(link: link, helper: helper))
        try AgentAccess.installCommand(link: link, helper: helper)
        XCTAssertTrue(AgentAccess.commandInstalled(link: link, helper: helper))
        // An older link is replaced; a real file someone put there is not.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        try AgentAccess.installCommand(link: link, helper: helper)
        XCTAssertTrue(AgentAccess.commandInstalled(link: link, helper: helper))
        try FileManager.default.removeItem(at: link)
        try Data("#!/bin/sh".utf8).write(to: link)
        XCTAssertThrowsError(try AgentAccess.installCommand(link: link, helper: helper))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "#!/bin/sh")
    }
}

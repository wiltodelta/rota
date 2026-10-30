@testable import RotaCore
import XCTest

private final class FakeControl: RunControl {
    var stopped = false
    var sent: [String] = []
    func stop() { stopped = true }
    func send(_ message: String) { sent.append(message) }
}

private final class FakeLauncher: RoutineLaunching {
    var specs: [LaunchSpec] = []
    var events: [RunEvents] = []
    var completions: [(RunOutcome) -> Void] { events.map(\.finished) }
    var controls: [FakeControl] = []
    var failure: Error?
    /// Reports this session from inside `launch`, as a runner that spins the run loop does.
    var sessionDuringLaunch: String?
    var finishDuringLaunch: RunOutcome?

    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        if let failure { throw failure }
        specs.append(spec)
        self.events.append(events)
        if let sessionDuringLaunch { events.session(sessionDuringLaunch) }
        if let finishDuringLaunch { events.finished(finishDuringLaunch) }
        let control = FakeControl()
        controls.append(control)
        return control
    }
}

private final class RecordingNotifier: RunNotifying {
    var outcomes: [RunOutcome] = []
    var paused: [String] = []
    var added: [String] = []
    func runEnded(_ record: RunRecord, routine: Routine) { outcomes.append(record.outcome) }
    func routinePaused(_ routine: Routine, failures: Int) { paused.append(routine.id) }
    func routineAdded(_ routine: Routine) { added.append(routine.id) }
}

@MainActor
final class SchedulerTests: XCTestCase {
    private var directory: URL!
    private var launcher: FakeLauncher!
    private var notifier: RecordingNotifier!
    private var scheduler: Scheduler!
    private var clock = Date(timeIntervalSince1970: 0)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        launcher = FakeLauncher()
        notifier = RecordingNotifier()
        clock = makeDate(hour: 9, minute: 0)
        scheduler = Scheduler(location: StorageLocation(root: directory,
                                                   logs: directory.appendingPathComponent("logs")),
                              launcher: launcher)
        scheduler.calendar = calendar
        scheduler.now = { [unowned self] in clock }
        scheduler.executable = { "/bin/\($0.rawValue)" }
        scheduler.notifier = notifier
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func makeDate(day: Int = 9, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func addDailyRoutine(enabled: Bool = true) -> Routine {
        let routine = Routine(id: "report", name: "Report", workingDirectory: "/p", schedule: "0 10 * * *",
                              harness: .codex, enabled: enabled, prompt: "go", timeLimitMinutes: 30)
        scheduler.save(routine)
        return routine
    }

    func testHistoryRefreshReusesDecodedRecords() throws {
        let routine = addDailyRoutine(enabled: false)
        scheduler.run(routine, trigger: .manual)
        launcher.completions[0](.succeeded)
        var reads = 0
        scheduler.readHistory = { history, id in
            reads += 1
            return history.records(for: id)
        }
        let records = scheduler.allRecords()
        XCTAssertEqual(records.count, 1)
        for _ in 0..<20 {
            XCTAssertEqual(scheduler.allRecords(), records)
            XCTAssertEqual(scheduler.records(for: routine.id), records)
            XCTAssertEqual(scheduler.unreadCount, 1)
        }
        XCTAssertEqual(reads, 1, "Repeated UI reads must not decode history again")
    }

    func testHistorySnapshotTracksChangesAndDeletion() throws {
        let routine = addDailyRoutine(enabled: false)
        XCTAssertTrue(scheduler.allRecords().isEmpty)
        scheduler.run(routine, trigger: .manual)
        let running = try XCTUnwrap(scheduler.allRecords().first)
        XCTAssertEqual(running.outcome, .running)
        XCTAssertEqual(scheduler.records(for: routine.id), [running])
        launcher.completions[0](.succeeded)
        let finished = try XCTUnwrap(scheduler.allRecords().first)
        XCTAssertEqual(finished.outcome, .succeeded)
        XCTAssertEqual(scheduler.unreadCount, 1)
        scheduler.markRead(finished)
        XCTAssertEqual(scheduler.unreadCount, 0)
        _ = scheduler.setAttention("Review the result", on: try XCTUnwrap(scheduler.allRecords().first))
        XCTAssertEqual(scheduler.attentionCount, 1)
        XCTAssertTrue(scheduler.deleteSession(finished))
        XCTAssertTrue(scheduler.allRecords().isEmpty)
        XCTAssertTrue(scheduler.records(for: routine.id).isEmpty)
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(scheduler.allRecords().count, 1)
        XCTAssertTrue(scheduler.delete(routine.id))
        XCTAssertTrue(scheduler.allRecords().isEmpty)
    }

    func testHistorySnapshotTracksRoutineMembership() throws {
        let routine = addDailyRoutine(enabled: false)
        scheduler.run(routine, trigger: .manual)
        launcher.completions[0](.succeeded)
        XCTAssertEqual(scheduler.allRecords().count, 1)
        scheduler.routines = []
        XCTAssertTrue(scheduler.allRecords().isEmpty)
        scheduler.routines = [routine]
        XCTAssertEqual(scheduler.allRecords().count, 1)
    }

    func testHistorySnapshotRefreshesAfterOrphanRecovery() throws {
        var routine = addDailyRoutine(enabled: false)
        routine.harness = .shell
        scheduler.save(routine)
        let record = RunRecord(routineID: routine.id, trigger: .manual, harness: .shell,
                               startedAt: clock, outcome: .running)
        scheduler.saveRecord(record)
        XCTAssertEqual(scheduler.allRecords().first?.outcome, .running)
        scheduler.isOnline = { false }
        scheduler.start()
        XCTAssertEqual(scheduler.allRecords().first?.outcome, .interrupted)
        XCTAssertEqual(scheduler.records(for: routine.id).first?.outcome, .interrupted)
    }

    func testSynchronousCompletionDoesNotRestoreRunningState() throws {
        let routine = addDailyRoutine()
        launcher.finishDuringLaunch = .succeeded
        scheduler.run(routine, trigger: .manual)
        XCTAssertNil(scheduler.active[routine.id])
        XCTAssertNil(scheduler.runStarts[routine.id])
        XCTAssertNil(scheduler.launchIDs[routine.id])
        XCTAssertEqual(scheduler.allRecords().first?.outcome, .succeeded)
        scheduler.stopAll()
        XCTAssertFalse(try XCTUnwrap(launcher.controls.first).stopped)
    }

    func testLateRunnerEventsCannotChangeANewerRun() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("first-session")
        launcher.completions[0](.succeeded)
        scheduler.run(routine, trigger: .manual)
        launcher.events[1].session("second-session")
        let second = try XCTUnwrap(scheduler.active[routine.id])
        launcher.events[0].session("stale-session")
        launcher.completions[0](.failed(exitCode: 1))
        XCTAssertEqual(scheduler.active[routine.id], second)
        XCTAssertEqual(notifier.outcomes, [.succeeded])
        launcher.completions[1](.succeeded)
    }

    func testLateRunnerEventsCannotChangeAContinuedSession() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("native-session")
        launcher.completions[0](.succeeded)
        let record = try XCTUnwrap(scheduler.allRecords().first)
        XCTAssertTrue(scheduler.message("Continue with another task", to: record))
        let continued = try XCTUnwrap(scheduler.active[routine.id])
        XCTAssertEqual(continued.id, record.id)
        launcher.events[0].session("stale-session")
        launcher.events[0].configuration(.init(model: "stale-model"))
        launcher.events[0].terminalState(.working)
        let replies = AnswerRecorder()
        launcher.events[0].question(.init(id: "stale", title: "Expired")) { replies.append($0) }
        launcher.completions[0](.failed(exitCode: 1))
        XCTAssertEqual(scheduler.active[routine.id], continued)
        XCTAssertEqual(notifier.outcomes, [.succeeded])
        XCTAssertEqual(replies.values.map(\.action), ["cancel"])
        launcher.completions[1](.succeeded)
    }

    func testRunningShellKeepsItsTerminalFallback() throws {
        var routine = addDailyRoutine()
        routine.harness = .shell
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("shell-screen")
        let record = try XCTUnwrap(scheduler.active[routine.id])
        let command = try XCTUnwrap(scheduler.terminalCommand(for: record))
        XCTAssertEqual(command.executable, "/usr/bin/screen")
        XCTAssertEqual(command.arguments, ["-r", "shell-screen"])
        launcher.completions[0](.succeeded)
        XCTAssertNil(scheduler.terminalCommand(for: record))
    }

    func testTerminalContinuationKeepsSessionAndDisablesSecondWriter() async throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("native-session")
        launcher.completions[0](.succeeded)
        var record = try XCTUnwrap(scheduler.allRecords().first)
        record = scheduler.setAttention("Waiting for your reply", on: record)
        let source = directory.appendingPathComponent("native.jsonl")
        try Data().write(to: source)
        let owner = try XCTUnwrap(scheduler)
        let awaitingRecord = record
        scheduler.terminalTranscript = { [weak owner] _, _ in
            if let owner { DispatchQueue.main.sync { MainActor.assumeIsolated { owner.markRead(awaitingRecord) } } }
            return source
        }
        let started = await scheduler.continueInTerminal(record)
        XCTAssertTrue(started)
        guard started else { return }
        XCTAssertEqual(scheduler.current(record.id)?.readAt, clock)
        XCTAssertEqual(launcher.specs.last?.mode, .terminal(.codex))
        XCTAssertEqual(launcher.specs.last?.arguments, ["resume", "native-session"])
        let active = try XCTUnwrap(scheduler.current(record.id))
        XCTAssertEqual(active.terminalState, .waiting)
        XCTAssertEqual(active.attention, "Waiting for your reply")
        XCTAssertFalse(scheduler.canMessage(record))
        var interrupted = active
        interrupted.outcome = .interrupted
        XCTAssertFalse(scheduler.resumable(interrupted), "Native prompts must not resume unattended")
        XCTAssertFalse(scheduler.message("second writer", to: record))
        let duplicate = await scheduler.continueInTerminal(record)
        XCTAssertFalse(duplicate)
        launcher.events[1].terminalInput()
        XCTAssertNil(scheduler.current(record.id)?.attention)
        clock = clock.addingTimeInterval(120)
        launcher.events[1].terminalState(.working)
        XCTAssertEqual(scheduler.runStartedAt(active), clock, "Idle terminal time is not agent working time")
        XCTAssertEqual(scheduler.current(record.id)?.statusTitle, "Working in Terminal")
        launcher.events[1].terminalState(.waiting)
        XCTAssertEqual(scheduler.current(record.id)?.statusTitle, "Waiting in Terminal")
        launcher.completions[1](.succeeded)
        XCTAssertTrue(scheduler.canMessage(record))
        XCTAssertEqual(scheduler.current(record.id)?.outcome, .succeeded)
        XCTAssertEqual(scheduler.history.records(for: routine.id).count, 1)
    }

    func testQuestionsRequireExplicitAnswersAndSurviveOrdinaryMessagesAndDismissal() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        let record = try XCTUnwrap(scheduler.active[routine.id])
        launcher.events[0].session("native-session")
        let replies = AnswerRecorder()
        let question = AgentQuestion(id: "q1", title: "Choose a color", fields: [.init(id: "color", title: "Color")])
        launcher.events[0].question(question) { replies.append($0) }
        XCTAssertEqual(scheduler.current(record.id)?.questions, [question])
        XCTAssertEqual(scheduler.attentionCount, 1)
        scheduler.dismissAttention(record)
        XCTAssertEqual(scheduler.attentionCount, 1)
        XCTAssertFalse(scheduler.message("unrelated", to: record))
        XCTAssertTrue(replies.values.isEmpty)
        XCTAssertThrowsError(try scheduler.answerQuestion("q1", on: record, answer: .init()))
        XCTAssertEqual(scheduler.current(record.id)?.questions?.count, 1)
        try scheduler.answerQuestion("q1", on: record, answer: .init(values: ["color": ["Blue"]]))
        XCTAssertEqual(replies.values, [.init(values: ["color": ["Blue"]])])
        XCTAssertEqual(scheduler.attentionCount, 0)
        XCTAssertTrue(scheduler.current(record.id)?.questions?.isEmpty != false)
        XCTAssertThrowsError(try scheduler.answerQuestion("q1", on: record, answer: .init(action: "cancel")))
    }

    func testOrdinaryMessagesStaySeparateFromPendingAsyncAnswersAcrossHarnesses() throws {
        for harness in [Harness.claude, .codex, .grok, .antigravity] {
            let routine = Routine(id: "message-" + harness.rawValue, name: "Message fixture",
                                  workingDirectory: "/synthetic", schedule: "0 10 * * *", harness: harness,
                                  enabled: false, prompt: "Synthetic prompt")
            scheduler.save(routine)
            let index = launcher.events.count
            scheduler.run(routine, trigger: .manual)
            launcher.events[index].session("synthetic-thread-" + harness.rawValue)
            let record = try XCTUnwrap(scheduler.active[routine.id])
            var question = AgentQuestion(id: "async", title: "Choose", fields: [.init(id: "note", title: "Note?")])
            question.replyViaMessage = true
            launcher.events[index].question(question) { _ in XCTFail("No RPC reply for async input") }
            XCTAssertTrue(scheduler.message("An unrelated message", to: record), harness.rawValue)
            XCTAssertEqual(launcher.controls[index].sent, ["An unrelated message"])
            XCTAssertEqual(scheduler.current(record.id)?.questions, [question])
            XCTAssertEqual(scheduler.current(record.id)?.attention, question.title)
            let blocking = AgentQuestion(id: "blocking", title: "Approval")
            launcher.events[index].question(blocking) { _ in }
            XCTAssertFalse(scheduler.message("Keep as a draft", to: record))
            scheduler.resolveQuestion(blocking.id, runID: record.id)
            launcher.completions[index](.succeeded)
            XCTAssertTrue(scheduler.message("A separate later turn", to: record), harness.rawValue)
            XCTAssertEqual(launcher.specs.last?.prompt, "A separate later turn")
            XCTAssertEqual(scheduler.current(record.id)?.questions, [question])
            XCTAssertEqual(scheduler.current(record.id)?.attention, question.title)
            launcher.completions.last?(.succeeded)
        }
    }

    func testAsyncQuestionsSurviveCompletionAndAnswerContinuesTheSameSession() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("native-thread")
        let record = try XCTUnwrap(scheduler.active[routine.id])
        var question = AgentQuestion(id: "async-1", title: "Choose", fields: [.init(id: "0", title: "Color?")])
        question.replyViaMessage = true
        let replies = AnswerRecorder()
        launcher.events[0].question(question) { replies.append($0) }
        launcher.events[0].question(question) { replies.append($0) }
        XCTAssertEqual(scheduler.current(record.id)?.questions?.count, 1, "replayed items are deduplicated")
        launcher.completions[0](.succeeded)
        XCTAssertEqual(scheduler.current(record.id)?.questions, [question])
        XCTAssertTrue(replies.values.isEmpty, "async questions have no outstanding RPC callback")
        XCTAssertThrowsError(try scheduler.answerQuestion(question.id, on: record, answer: .init()))
        try scheduler.answerQuestion(question.id, on: record, answer: .init(values: ["0": ["Blue"]]))
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(launcher.specs.last?.resume, "native-thread")
        XCTAssertTrue(launcher.specs.last?.prompt.contains("Blue") == true)
        XCTAssertTrue(launcher.specs.last?.prompt.contains("Color?") == true)
        XCTAssertEqual(scheduler.current(record.id)?.questions, [question], "retain until native delivery succeeds")
        XCTAssertThrowsError(try scheduler.answerQuestion(question.id, on: record, answer: .init(action: "cancel")))
        launcher.events[1].questionResolved(question.id)
        XCTAssertTrue(scheduler.current(record.id)?.questions?.isEmpty != false)
        XCTAssertThrowsError(try scheduler.answerQuestion(question.id, on: record, answer: .init(action: "cancel")))
    }

    func testAsyncQuestionsSurviveRestartAndFailedContinuationWithoutLosingOtherQuestions() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("native-thread")
        let record = try XCTUnwrap(scheduler.active[routine.id])
        for id in ["first", "second"] {
            var question = AgentQuestion(id: id, title: id)
            question.replyViaMessage = true
            launcher.events[0].question(question) { _ in XCTFail("No RPC callback for async input") }
        }
        let location = StorageLocation(root: directory, logs: directory.appendingPathComponent("logs"))
        scheduler.history.closeOrphans(routineIDs: [routine.id], now: clock)
        let restored = Scheduler(location: location, launcher: launcher)
        restored.executable = { "/bin/\($0.rawValue)" }
        XCTAssertEqual(restored.current(record.id)?.questions?.map(\.id), ["first", "second"])
        launcher.failure = NSError(domain: "Synthetic launch failure", code: 1)
        XCTAssertThrowsError(try restored.answerQuestion("first", on: record, answer: .init(action: "decline")))
        XCTAssertEqual(restored.current(record.id)?.questions?.map(\.id), ["first", "second"])
        launcher.failure = nil
        try restored.answerQuestion("first", on: record, answer: .init(action: "cancel"))
        launcher.events.last?.questionResolved("first")
        XCTAssertEqual(restored.current(record.id)?.questions?.map(\.id), ["second"])
        XCTAssertTrue(launcher.specs.last?.prompt.contains("cancel") == true)
        try restored.answerQuestion("second", on: record, answer: .init(action: "decline"))
        XCTAssertTrue(launcher.controls.last?.sent.last?.contains("decline") == true)
        launcher.events.last?.questionResolved("second")
        XCTAssertTrue(restored.current(record.id)?.questions?.isEmpty != false)
    }

    func testCodexAnswerSurvivesAsynchronousLaunchFailureAndRestartUntilAcknowledged() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("native-thread")
        let record = try XCTUnwrap(scheduler.active[routine.id])
        var question = AgentQuestion(id: "call-retry", title: "Choose", fields: [.init(id: "0", title: "Color?")])
        question.replyViaMessage = true
        launcher.events[0].question(question) { _ in XCTFail("Async input has no RPC reply") }
        launcher.completions[0](.succeeded)
        try scheduler.answerQuestion(question.id, on: record, answer: .init(values: ["0": ["Blue"]]))
        XCTAssertThrowsError(try scheduler.answerQuestion(question.id, on: record, answer: .init(action: "cancel")))
        launcher.completions[1](.launchFailed("synthetic failure before history loaded"))
        XCTAssertEqual(scheduler.current(record.id)?.questions, [question])
        let location = StorageLocation(root: directory, logs: directory.appendingPathComponent("logs"))
        let restored = Scheduler(location: location, launcher: launcher)
        restored.executable = { "/bin/\($0.rawValue)" }
        XCTAssertEqual(restored.current(record.id)?.questions, [question])
        try restored.answerQuestion(question.id, on: record, answer: .init(action: "cancel"))
        launcher.events.last?.questionResolved(question.id)
        launcher.completions.last?(.succeeded)
        XCTAssertTrue(restored.current(record.id)?.questions?.isEmpty != false)
        XCTAssertTrue(restored.history.records(for: routine.id).first?.questions?.isEmpty != false)
    }

    func testAntigravityCancellationAndDeclineSendInstructionsWithoutGrantingPermissions() throws {
        var routine = addDailyRoutine()
        routine.harness = .antigravity
        scheduler.save(routine)
        for action in ["cancel", "decline"] {
            let index = launcher.events.count
            scheduler.run(routine, trigger: .manual)
            launcher.events[index].session("native-conversation")
            let record = try XCTUnwrap(scheduler.active[routine.id])
            let question = try XCTUnwrap(QuestionRequest.antigravity("ask_permission", arguments: [:], id: action))
            launcher.events[index].question(question) { _ in XCTFail("No suspended native RPC exists") }
            launcher.events[index].finished(.succeeded)
            try scheduler.answerQuestion(question.id, on: record, answer: .init(action: action))
            let spec = try XCTUnwrap(launcher.specs.last)
            XCTAssertEqual(spec.resume, "native-conversation")
            let body = spec.prompt.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? ""
            let message = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            XCTAssertEqual(message?["action"] as? String, action)
            XCTAssertEqual(scheduler.current(record.id)?.questions?.count, 0)
            launcher.events[index + 1].finished(.succeeded)
        }
    }

    func testBlockingQuestionsTakePriorityOverEarlierAsyncQuestions() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("native-thread")
        let record = try XCTUnwrap(scheduler.active[routine.id])
        var async = AgentQuestion(id: "async", title: "Async choice")
        async.replyViaMessage = true
        launcher.events[0].question(async) { _ in XCTFail("No RPC for async input") }
        let replies = AnswerRecorder()
        launcher.events[0].question(.init(id: "blocking", title: "Blocking choice")) { replies.append($0) }
        XCTAssertEqual(scheduler.current(record.id)?.nextQuestion?.id, "blocking")
        XCTAssertThrowsError(try scheduler.answerQuestion("async", on: record, answer: .init()))
        XCTAssertTrue(launcher.controls[0].sent.isEmpty)
        try scheduler.answerQuestion("blocking", on: record, answer: .init(action: "cancel"))
        XCTAssertEqual(replies.values.map(\.action), ["cancel"])
        XCTAssertEqual(scheduler.current(record.id)?.nextQuestion?.id, "async")
        try scheduler.answerQuestion("async", on: record, answer: .init(action: "decline"))
        launcher.events.last?.questionResolved("async")
        XCTAssertTrue(launcher.controls[0].sent.last?.contains("decline") == true)
    }

    func testMultipleQuestionsResolveIndependentlyAndFinishCancelsTheRest() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        let record = try XCTUnwrap(scheduler.active[routine.id])
        let replies = AnswerRecorder()
        for id in ["a", "b"] {
            launcher.events[0].question(.init(id: id, title: id)) { replies.append($0) }
        }
        try scheduler.answerQuestion("a", on: record, answer: .init(action: "decline"))
        XCTAssertEqual(scheduler.current(record.id)?.questions?.map(\.id), ["b"])
        XCTAssertEqual(scheduler.current(record.id)?.attention, "b")
        launcher.events[0].finished(.cancelled)
        XCTAssertEqual(replies.values.map(\.action), ["decline", "cancel"])
        XCTAssertTrue(scheduler.current(record.id)?.questions?.isEmpty != false)
        XCTAssertEqual(scheduler.attentionCount, 0)
    }

    func testHookPollingReturnsTheActualAnswerOnceAndExpiresAfterStop() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        let record = try XCTUnwrap(scheduler.active[routine.id])
        let question = AgentQuestion(id: "hook", title: "Test question")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(question))
        _ = try scheduler.questionCommand("questions.create", ["session": record.id.uuidString, "question": encoded])
        let params: [String: Any] = ["session": record.id.uuidString, "question": "hook"]
        XCTAssertEqual((try scheduler.questionCommand("questions.poll", params) as? [String: Bool])?["pending"], true)
        try scheduler.answerQuestion("hook", on: record, answer: .init(action: "decline"))
        let answer = try scheduler.questionCommand("questions.poll", params) as? [String: Any]
        XCTAssertEqual(answer?["action"] as? String, "decline")
        XCTAssertThrowsError(try scheduler.questionCommand("questions.poll", params))
        _ = try scheduler.questionCommand("questions.create", ["session": record.id.uuidString, "question": encoded])
        scheduler.stop(routine.id)
        XCTAssertTrue(scheduler.current(record.id)?.questions == nil)
        XCTAssertThrowsError(try scheduler.questionCommand("questions.poll", params))
    }

    func testSavingAnEnabledRoutineSchedulesItsNextSlot() {
        _ = addDailyRoutine()
        XCTAssertEqual(scheduler.routine("report")?.nextFire, makeDate(hour: 10, minute: 0))
        scheduler.setEnabled(false, for: "report")
        XCTAssertNil(scheduler.routine("report")?.nextFire)
    }

    func testDeletionAvailabilityUsesDisplayHistoryButDeletionRechecksStorage() throws {
        let routine = addDailyRoutine(enabled: false)
        let record = RunRecord(routineID: routine.id, trigger: .manual, harness: .codex,
                               startedAt: clock, endedAt: clock, outcome: .succeeded)
        scheduler.saveRecord(record)
        XCTAssertEqual(scheduler.records(for: routine.id), [record])
        // Change the producer's storage without invalidating the displayed snapshot.
        XCTAssertTrue(try scheduler.history.remove(record.id, for: routine.id))
        XCTAssertTrue(scheduler.history.records(for: routine.id).isEmpty)
        for _ in 0..<20 {
            XCTAssertTrue(scheduler.canDelete(record), "Drawing a row must reuse the display snapshot")
        }
        XCTAssertFalse(scheduler.deleteSession(record), "The action must recheck storage")
        scheduler.historyVersion += 1
        XCTAssertFalse(scheduler.canDelete(record), "Invalidation must refresh availability")
    }

    func testSessionDeletionRechecksActiveStateAndCancelsPendingResume() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        var stale = try XCTUnwrap(scheduler.active[routine.id])
        stale.outcome = .succeeded
        XCTAssertFalse(scheduler.canDelete(stale))
        XCTAssertFalse(scheduler.deleteSession(stale))
        XCTAssertEqual(scheduler.history.records(for: routine.id).count, 1)
        launcher.completions[0](.succeeded)
        let finished = try XCTUnwrap(scheduler.history.records(for: routine.id).first)
        XCTAssertTrue(scheduler.canDelete(finished))
        scheduler.pendingResumes[finished.id] = routine.id
        let version = scheduler.historyVersion
        XCTAssertTrue(scheduler.deleteSession(finished), scheduler.lastError ?? "")
        XCTAssertNil(scheduler.pendingResumes[finished.id])
        XCTAssertTrue(scheduler.history.records(for: routine.id).isEmpty)
        XCTAssertNotNil(scheduler.routine(routine.id))
        XCTAssertGreaterThan(scheduler.historyVersion, version)
        scheduler.markRead(finished)
        XCTAssertTrue(scheduler.history.records(for: routine.id).isEmpty, "Closing the deleted view must not revive it")
    }

    func testReportedConfigurationSurvivesFinishAndStaleRecordsDoNotResetIt() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        let initial = try XCTUnwrap(scheduler.active[routine.id])
        launcher.events[0].session("fixture-session")
        launcher.events[0].configuration(SessionConfiguration(model: "reported-model", effort: "high",
                                                            modelTitle: "Reported model"))
        XCTAssertNil(scheduler.current(initial.id, routineID: routine.id)?.model)
        XCTAssertEqual(scheduler.active[routine.id]?.reportedModel, "reported-model")
        XCTAssertEqual(scheduler.active[routine.id]?.reportedModelTitle, "Reported model")
        XCTAssertEqual(scheduler.history.records(for: routine.id).first?.reportedEffort, "high")
        XCTAssertTrue(scheduler.message("message from a stale view", to: initial))
        XCTAssertEqual(launcher.controls[0].sent, ["message from a stale view"])
        launcher.completions[0](.succeeded)
        XCTAssertEqual(scheduler.history.records(for: routine.id).first?.reportedModel, "reported-model")
        XCTAssertEqual(scheduler.history.records(for: routine.id).first?.reportedModelTitle, "Reported model")
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].configuration(SessionConfiguration(model: "stale-model"))
        XCTAssertNil(scheduler.active[routine.id]?.reportedModel, "Old sessions cannot overwrite a new run")
    }

    func testDeletionRechecksAnInteractiveSessionThatOutlivedTheApp() throws {
        let routine = addDailyRoutine()
        var record = RunRecord(routineID: routine.id, trigger: .manual, harness: .claude,
                               startedAt: clock, endedAt: clock, outcome: .interrupted)
        record.sessionID = "synthetic-session"
        scheduler.saveRecord(record)
        var probes = 0
        scheduler.sessionAlive = { _ in probes += 1; return true }
        XCTAssertTrue(scheduler.canDelete(record))
        XCTAssertEqual(probes, 0, "Drawing the UI must not probe a process")
        XCTAssertFalse(scheduler.deleteSession(record))
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(scheduler.history.records(for: routine.id), [record])
    }

    func testFiresWhenDueAndBuildsTheHarnessCommand() throws {
        _ = addDailyRoutine()
        clock = makeDate(hour: 9, minute: 59)
        scheduler.tick()
        XCTAssertTrue(launcher.specs.isEmpty)

        clock = makeDate(hour: 10, minute: 0)
        scheduler.tick()
        let spec = try XCTUnwrap(launcher.specs.first)
        XCTAssertEqual(spec.executable, "/bin/codex")
        XCTAssertEqual(spec.mode, .codexDaemon)
        XCTAssertEqual(spec.workingDirectory, "/p")
        XCTAssertEqual(spec.timeout, 30 * 60)
        XCTAssertNotNil(scheduler.active["report"])
        XCTAssertEqual(scheduler.routine("report")?.nextFire, makeDate(day: 10, hour: 10, minute: 0))

        launcher.completions[0](.succeeded)
        XCTAssertNil(scheduler.active["report"])
        XCTAssertEqual(scheduler.history.records(for: "report").map(\.outcome), [.succeeded])
        XCTAssertEqual(notifier.outcomes, [.succeeded])
    }

    func testDisabledRoutineNeverFires() {
        _ = addDailyRoutine(enabled: false)
        clock = makeDate(hour: 10, minute: 0)
        scheduler.tick()
        XCTAssertTrue(launcher.specs.isEmpty)
    }

    func testMissedSlotsRunOnceLateAsACatchUp() throws {
        _ = addDailyRoutine()
        // Three daily slots passed while the Mac slept: one run, marked as a catch-up.
        clock = makeDate(day: 12, hour: 9, minute: 0)
        scheduler.tick()
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(scheduler.active["report"]?.trigger, .catchUp)
        XCTAssertEqual(scheduler.routine("report")?.nextFire, makeDate(day: 12, hour: 10, minute: 0))
        launcher.completions[0](.succeeded)
        scheduler.tick()
        XCTAssertEqual(launcher.specs.count, 1, "no second catch-up")
    }

    func testOnTimeSlotIsScheduledNotCatchUp() {
        _ = addDailyRoutine()
        clock = makeDate(hour: 10, minute: 1)
        scheduler.tick()
        XCTAssertEqual(scheduler.active["report"]?.trigger, .scheduled)
    }

    func testSlotMissedBeyondGraceIsSkippedNotRun() {
        _ = addDailyRoutine()
        clock = makeDate(day: 17, hour: 10, minute: 1)
        scheduler.tick()
        XCTAssertTrue(launcher.specs.isEmpty)
        guard case .skipped = scheduler.history.records(for: "report").first?.outcome else {
            return XCTFail("expected a skipped record")
        }
        XCTAssertEqual(scheduler.routine("report")?.nextFire, makeDate(day: 18, hour: 10, minute: 0))
    }

    func testFiveFailuresInARowPauseTheRoutine() {
        _ = addDailyRoutine()
        for day in 9..<14 {
            clock = makeDate(day: day, hour: 10, minute: 0)
            scheduler.tick()
            launcher.completions.last?(.failed(exitCode: 1))
            if day < 13 { XCTAssertEqual(scheduler.routine("report")?.enabled, true, "day \(day)") }
        }
        XCTAssertEqual(scheduler.routine("report")?.enabled, false)
        XCTAssertEqual(notifier.paused, ["report"])
    }

    func testOverlapSkipsAndManualFailuresDoNotPause() {
        let routine = addDailyRoutine()
        for _ in 0..<5 {
            scheduler.run(routine, trigger: .manual)
            launcher.completions.last?(.failed(exitCode: 1))
        }
        XCTAssertEqual(scheduler.routine("report")?.enabled, true)

        // A long run overlapping five slots: five skips, still on.
        var minutely = routine
        minutely.schedule = "* * * * *"
        scheduler.save(minutely)
        clock = clock.addingTimeInterval(60)
        scheduler.tick()
        for _ in 0..<5 {
            clock = clock.addingTimeInterval(60)
            scheduler.tick()
        }
        launcher.completions.last?(.failed(exitCode: 1))
        XCTAssertEqual(scheduler.routine("report")?.enabled, true)
        XCTAssertTrue(notifier.outcomes.filter { if case .skipped = $0 { return true }; return false }.isEmpty,
                      "overlap skips do not notify")
    }

    func testSkippedSlotsStayOutOfTheSessionsList() {
        _ = addDailyRoutine()
        clock = makeDate(day: 17, hour: 10, minute: 1)
        scheduler.tick()
        XCTAssertEqual(scheduler.history.records(for: "report").count, 1, "the skip is recorded")
        XCTAssertTrue(scheduler.allRecords().isEmpty, "but is not a session")
        XCTAssertEqual(scheduler.unreadCount, 0)
    }

    func testFinishedSessionIsUnreadUntilOpened() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(scheduler.unreadCount, 0, "a running session is not unread")
        launcher.completions[0](.succeeded)
        let record = try XCTUnwrap(scheduler.history.records(for: "report").first)
        XCTAssertTrue(record.isUnread)
        XCTAssertEqual(scheduler.unreadCount, 1)
        clock = clock.addingTimeInterval(60)
        scheduler.markRead(record)
        XCTAssertFalse(try XCTUnwrap(scheduler.history.records(for: "report").first).isUnread)
        XCTAssertEqual(scheduler.unreadCount, 0)
    }

    func testOverlappingSlotIsSkippedWhileThePreviousRunGoes() {
        var routine = addDailyRoutine()
        routine.schedule = "* * * * *"
        scheduler.save(routine)
        clock = makeDate(hour: 9, minute: 1)
        scheduler.tick()
        clock = makeDate(hour: 9, minute: 2)
        scheduler.tick()
        XCTAssertEqual(launcher.specs.count, 1)
        let outcomes = scheduler.history.records(for: "report").map(\.outcome)
        XCTAssertEqual(outcomes.first, .skipped("the previous run was still going"))
    }

    func testStopReachesTheRunningProcess() {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        scheduler.stop("report")
        XCTAssertTrue(launcher.controls[0].stopped)
        launcher.completions[0](.cancelled)
        XCTAssertEqual(scheduler.history.records(for: "report").first?.trigger, .manual)
        XCTAssertEqual(notifier.outcomes, [.cancelled])
    }

    func testStopAllReachesEveryRunningProcess() {
        let first = addDailyRoutine()
        let second = Routine(id: "digest", name: "Digest", workingDirectory: "/p", schedule: "0 10 * * *",
                             harness: .shell, enabled: true, prompt: "true")
        scheduler.save(second)
        scheduler.run(first, trigger: .manual)
        scheduler.run(second, trigger: .manual)
        scheduler.stopAll()
        XCTAssertEqual(launcher.controls.map(\.stopped), [true, true])
    }

    func testLaunchFailureIsRecorded() {
        let routine = addDailyRoutine()
        launcher.failure = LaunchError.missingExecutable("/bin/codex")
        scheduler.run(routine, trigger: .manual)
        XCTAssertNil(scheduler.active["report"])
        XCTAssertEqual(scheduler.history.records(for: "report").first?.outcome,
                       .launchFailed("no executable at /bin/codex"))
    }

    func testRoutinesSurviveARestart() {
        _ = addDailyRoutine()
        let reopened = Scheduler(location: StorageLocation(root: directory, logs: directory),
                                 launcher: launcher)
        XCTAssertEqual(reopened.routines.map(\.id), ["report"])
        XCTAssertEqual(reopened.routines.first?.nextFire, makeDate(hour: 10, minute: 0))
    }

    func testClaudeRunTakesMessagesAndResumesWithItsSession() throws {
        var routine = addDailyRoutine()
        routine.harness = .claude
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        let spec = try XCTUnwrap(launcher.specs.first)
        XCTAssertEqual(spec.mode, .claudeStream)
        XCTAssertEqual(spec.prompt, "go")
        XCTAssertFalse(spec.arguments.contains("--resume"))
        launcher.events[0].session("abc123")
        let running = try XCTUnwrap(scheduler.active["report"])
        XCTAssertEqual(running.sessionID, "abc123")
        XCTAssertTrue(scheduler.canMessage(running))
        XCTAssertNil(scheduler.terminalCommand(for: running))
        launcher.completions[0](.succeeded)
        let finished = try XCTUnwrap(scheduler.history.records(for: "report").first)
        XCTAssertEqual(scheduler.terminalCommand(for: finished)?.arguments, ["--resume", "abc123"])
        scheduler.message("and then?", to: finished)
        XCTAssertEqual(Array(try XCTUnwrap(launcher.specs.last).arguments.suffix(2)), ["--resume", "abc123"])
    }

    func testARunTakesAsLongAsItNeedsUnlessTheRoutineSetsALimit() throws {
        var routine = addDailyRoutine()
        routine.timeLimitMinutes = nil
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        XCTAssertNil(try XCTUnwrap(launcher.specs.last).timeout)
        launcher.completions[0](.succeeded)
        routine.timeLimitMinutes = 90
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(try XCTUnwrap(launcher.specs.last).timeout, 90 * 60)
        XCTAssertNil(Routine(id: "r", name: "R", workingDirectory: "/p", schedule: "0 9 * * *", prompt: "go")
            .timeLimitMinutes, "a new routine has no limit")
    }

    func testTheRoutinesModelReachesTheRunAndItsContinuation() throws {
        var routine = addDailyRoutine()
        routine.model = "gpt-6-luna"
        routine.effort = "high"
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("thread-1")
        launcher.completions[0](.succeeded)
        let finished = try XCTUnwrap(scheduler.history.records(for: "report").first)
        routine.model = "gpt-6-sol"
        routine.effort = "low"
        scheduler.save(routine)
        scheduler.message("and then?", to: finished)
        XCTAssertEqual(launcher.specs.map(\.model), ["gpt-6-luna", "gpt-6-luna"])
        XCTAssertEqual(launcher.specs.map(\.effort), ["high", "high"])
    }

    func testFiftyOverlapSkipsKeepTheRunningSessionAndLogAfterCompletion() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var routine = addDailyRoutine()
        routine.workingDirectory = directory.path
        routine.schedule = "* * * * *"
        routine.timeLimitMinutes = nil
        XCTAssertNil(routine.problem())
        scheduler.save(routine)
        clock = clock.addingTimeInterval(60)
        scheduler.tick()
        let running = try XCTUnwrap(scheduler.active[routine.id])
        let log = try XCTUnwrap(running.logPath)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: log).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("first output\n".utf8).write(to: URL(fileURLWithPath: log))
        for _ in 0..<50 {
            clock = clock.addingTimeInterval(60)
            scheduler.tick()
        }
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(scheduler.active[routine.id]?.id, running.id)
        XCTAssertEqual(scheduler.allRecords().map(\.id), [running.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: log))
        launcher.completions[0](.succeeded)
        XCTAssertEqual(scheduler.allRecords().map(\.id), [running.id])
        XCTAssertEqual(scheduler.allRecords().first?.outcome, .succeeded)
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "first output\n")
        XCTAssertEqual(scheduler.history.records(for: routine.id).filter(\.isSkip).count, 50)
    }

    func testCodexRunTakesMessagesWhileRunningAndContinuesAfter() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(launcher.specs.first?.mode, .codexDaemon)
        XCTAssertNil(launcher.specs.first?.resume)
        launcher.events[0].session("thread-1")
        let running = try XCTUnwrap(scheduler.active["report"])
        XCTAssertTrue(scheduler.canMessage(running))
        XCTAssertNil(scheduler.terminalCommand(for: running))
        scheduler.message("also check the logs", to: running)
        XCTAssertEqual(launcher.controls[0].sent, ["also check the logs"])
        launcher.completions[0](.succeeded)

        // Afterwards a message continues the same session as a run of its own.
        let finished = try XCTUnwrap(scheduler.history.records(for: "report").first)
        XCTAssertEqual(scheduler.terminalCommand(for: finished)?.arguments, ["resume", "thread-1"])
        scheduler.message("one more thing", to: finished)
        let follow = try XCTUnwrap(launcher.specs.last)
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(follow.resume, "thread-1")
        XCTAssertEqual(follow.prompt, "one more thing")
        XCTAssertEqual(follow.log.path, finished.logPath)
        XCTAssertEqual(scheduler.active["report"]?.id, finished.id, "the same session is running again")
        XCTAssertEqual(scheduler.history.records(for: "report").count, 1)
        launcher.completions[1](.succeeded)
        XCTAssertEqual(scheduler.history.records(for: "report").first?.outcome, .succeeded)
    }

    /// A message that reaches a run whose session is ending continues the session once the run ends.
    func testLateMessageContinuesTheSessionAfterTheRun() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("thread-1")
        launcher.events[0].undelivered("first late")
        launcher.events[0].undelivered("second late")
        XCTAssertEqual(launcher.specs.count, 1, "nothing starts while the run is still active")
        launcher.completions[0](.succeeded)
        let follow = try XCTUnwrap(launcher.specs.last)
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(follow.resume, "thread-1")
        XCTAssertEqual(follow.prompt, "first late\n\nsecond late")

        // One handed back after the run already ended continues at once.
        launcher.completions[1](.succeeded)
        launcher.events[1].undelivered("after the end")
        XCTAssertEqual(launcher.specs.count, 3)
        XCTAssertEqual(launcher.specs.last?.prompt, "after the end")
        XCTAssertEqual(scheduler.history.records(for: "report").count, 1, "the same session continues")
    }

    func testSessionReportedDuringLaunchIsKept() throws {
        let routine = addDailyRoutine()
        launcher.sessionDuringLaunch = "early-1"
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(scheduler.history.records(for: "report").first?.sessionID, "early-1")
        XCTAssertEqual(scheduler.active["report"]?.sessionID, "early-1")
    }

    func testFinishedSessionWaitsWhileAnotherRunOfTheRoutineWorks() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("thread-1")
        launcher.completions[0](.succeeded)
        let old = try XCTUnwrap(scheduler.history.records(for: "report").first)
        scheduler.run(routine, trigger: .manual)
        XCTAssertFalse(scheduler.canMessage(old))
        scheduler.message("hello", to: old)
        XCTAssertEqual(launcher.specs.count, 2, "no third launch")
    }

    func testMessageIsRejectedWhenContinuationCannotLaunch() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("thread-1")
        launcher.completions[0](.succeeded)
        let record = try XCTUnwrap(scheduler.history.records(for: routine.id).first)
        launcher.failure = NSError(domain: "Synthetic launch failure", code: 1)
        XCTAssertFalse(scheduler.message("Keep my draft", to: record))
        XCTAssertNil(scheduler.active[routine.id])
    }

    func testShellRoutineRunsItsCommand() throws {
        var routine = addDailyRoutine()
        routine.harness = .shell
        routine.prompt = "echo hello"
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(launcher.specs.first?.prompt, "echo hello")
        XCTAssertEqual(launcher.specs.first?.mode, .screen)
    }

    func testDeleteRemovesRoutineAndHistory() {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.completions[0](.succeeded)
        scheduler.delete("report")
        XCTAssertNil(scheduler.routine("report"))
        XCTAssertTrue(scheduler.history.records(for: "report").isEmpty)
    }

    func testDeletingARunningRoutineRejectsItsLateCallbacks() {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        scheduler.delete(routine.id)
        launcher.events[0].session("late-session")
        launcher.completions[0](.cancelled)
        XCTAssertNil(scheduler.active[routine.id])
        XCTAssertTrue(scheduler.history.records(for: routine.id).isEmpty)
        XCTAssertTrue(launcher.controls[0].stopped)
    }

    func testFailedSaveDoesNotPublishAnUnsavedRoutine() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("routines.json"),
                                                withIntermediateDirectories: true)
        _ = addDailyRoutine()
        XCTAssertTrue(scheduler.routines.isEmpty)
        XCTAssertNotNil(scheduler.lastError)
    }
}

private final class AnswerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [QuestionAnswer] = []
    var values: [QuestionAnswer] { lock.lock(); defer { lock.unlock() }; return answers }
    func append(_ answer: QuestionAnswer) { lock.lock(); answers.append(answer); lock.unlock() }
}

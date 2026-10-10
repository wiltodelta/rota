@testable import RotaCore
import XCTest

/// Real runs against the installed CLIs, skipped unless ROTA_LIVE=1: each starts
/// a harmless task, sends a message into it while it works, and checks the reply
/// reached the log. They spend a little of each vendor's quota.
final class LiveHarnessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROTA_LIVE"] == "1", "set ROTA_LIVE=1 to run")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-live-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func run(_ harness: Harness, prompt: String, message: String?, timeout: TimeInterval = 240,
                     directory: String? = nil, resume: String? = nil,
                     stopAfter: TimeInterval? = nil, model: String? = nil,
                     effort: String? = nil) throws -> (RunOutcome, String, String?) {
        let log = folder.appendingPathComponent("\(harness.rawValue).log")
        let spec = LaunchSpec(executable: harness.defaultExecutable(), prompt: prompt,
                              arguments: harness.arguments(needs: [], resume: resume),
                              workingDirectory: directory ?? folder.path, environment: [:], mode: harness.launchMode,
                              timeout: timeout, log: log, resume: resume, model: model, effort: effort)
        let ended = expectation(description: "run ended")
        var outcome: RunOutcome?
        var session: String?
        var control: RunControl?
        let events = RunEvents(session: { id in
            session = id
            if let stopAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) { control?.stop() }
            }
            guard let message else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { control?.send(message) }
        }, finished: { result in
            outcome = result
            ended.fulfill()
        })
        control = try ProcessLauncher().launch(spec, events: events)
        wait(for: [ended], timeout: timeout + 30)
        let text = try String(contentsOf: log, encoding: .utf8)
        print("---- \(harness.rawValue) log\n\(text)----")
        return (try XCTUnwrap(outcome), text, session)
    }

    private let steerable = "Run the shell command `sleep 15; echo first`. When it is done, reply with exactly "
        + "the phrase a later user message gives you, or with the word done if there is none."

    func testCodexTakesAMessageMidTurn() throws {
        let (outcome, log, session) = try run(.codex, prompt: steerable, message: "Reply with exactly: purple otter")
        XCTAssertEqual(outcome, .succeeded, log)
        XCTAssertNotNil(session)
        XCTAssertTrue(log.contains("[you] Reply with exactly: purple otter"), log)
        XCTAssertTrue(log.lowercased().contains("purple otter\n") || log.lowercased().hasSuffix("purple otter"), log)
    }

    /// Grok answers a message sent mid-turn after that turn; the run waits for the answer.
    func testGrokTakesAMessageIntoTheSession() throws {
        let (outcome, log, session) = try run(.grok, prompt: steerable, message: "Reply with exactly: purple otter")
        XCTAssertEqual(outcome, .succeeded, log)
        XCTAssertNotNil(session)
        XCTAssertTrue(log.contains("[you] Reply with exactly: purple otter"), log)
        XCTAssertTrue(log.lowercased().contains("purple otter\n[rota: succeeded"), log)
    }

    /// A finished session takes a follow-up message as a new run of the same session.
    private func checkContinuation(_ harness: Harness, directory: String? = nil) throws {
        let (first, _, session) = try run(harness, prompt: "Reply with exactly: red fox", message: nil,
                                          directory: directory)
        XCTAssertEqual(first, .succeeded)
        let id = try XCTUnwrap(session)
        let (second, log, again) = try run(harness, prompt: "Now reply with exactly: blue whale", message: nil,
                                           directory: directory, resume: id)
        XCTAssertEqual(second, .succeeded, log)
        XCTAssertEqual(again, id, "the same session continues")
        XCTAssertTrue(log.contains("red fox") && log.lowercased().contains("blue whale"), log)
        XCTAssertEqual(log.components(separatedBy: "red fox").count, 3, "the first answer is not copied twice: \(log)")
    }

    func testCodexContinuesAFinishedSession() throws { try checkContinuation(.codex) }

    func testGrokContinuesAFinishedSession() throws { try checkContinuation(.grok) }

    /// Claude takes a message sent mid-turn into the same turn.
    func testClaudeTakesAMessageMidTurn() throws {
        let (outcome, log, session) = try run(.claude, prompt: steerable, message: "Reply with exactly: purple otter")
        XCTAssertEqual(outcome, .succeeded, log)
        XCTAssertNotNil(session)
        XCTAssertTrue(log.contains("[you] Reply with exactly: purple otter"), log)
        XCTAssertTrue(log.lowercased().contains("purple otter\n"), log)
    }

    func testClaudeContinuesAFinishedSession() throws { try checkContinuation(.claude) }

    func testShellRunsInScreenWithItsExitStatus() throws {
        let (outcome, log, session) = try run(.shell, prompt: "echo hello from screen; sleep 3; exit 5", message: nil)
        XCTAssertEqual(outcome, .failed(exitCode: 5), log)
        XCTAssertTrue(session?.hasPrefix("rota-") == true)
        XCTAssertTrue(log.contains("hello from screen"), log)
    }

    /// Quitting Rota stops every run and gives them five seconds to end; the log prints how long each took.
    func testEveryHarnessStops() throws {
        for harness in Harness.allCases {
            let prompt = harness == .shell ? "sleep 60" : steerable
            let started = Date()
            let (outcome, log, _) = try run(harness, prompt: prompt, message: nil, timeout: 120, stopAfter: 6)
            let elapsed = Date().timeIntervalSince(started)
            print("\(harness.rawValue) stopped \(elapsed) s after launch")
            XCTAssertEqual(outcome, .cancelled, "\(harness.rawValue): \(log)")
        }
    }

    /// Each agent runs on the model the routine picks, and Grok's own default stays as it was.
    func testEveryAgentRunsOnTheChosenModel() throws {
        let grokDefault = { ProcessLauncher.capture(Harness.grok.defaultExecutable(), ["models"],
                                                    in: NSTemporaryDirectory()).1
            .split(separator: "\n").first { $0.hasPrefix("Default model:") } }
        let before = grokDefault()
        let picks: [(Harness, String, String, String)] = [
            (.claude, "haiku", "low", "haiku"), (.codex, "gpt-6-luna", "low", "gpt-6-luna"),
            (.grok, "grok-4.6", "low", "grok-4.6")
        ]
        for (harness, model, effort, expected) in picks {
            let (outcome, log, _) = try run(harness, prompt: "Reply with exactly: ok", message: nil,
                                            model: model, effort: effort)
            XCTAssertEqual(outcome, .succeeded, log)
            let header = log.split(separator: "\n").first { Transcript.isHeader(String($0)) } ?? ""
            XCTAssertTrue(header.contains(expected), "\(harness.rawValue) header: \(header)")
        }
        XCTAssertEqual(grokDefault(), before, "a routine's model must not change Grok's default")
    }

    /// A command that ends at once used to race the poll and read as interrupted.
    func testShellCommandThatFailsAtOnceKeepsItsStatus() throws {
        for _ in 0..<5 {
            let (outcome, log, _) = try run(.shell, prompt: "exit 3", message: nil)
            XCTAssertEqual(outcome, .failed(exitCode: 3), log)
        }
    }
}

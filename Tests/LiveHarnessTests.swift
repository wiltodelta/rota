@testable import RotaCore
import AppKit
import XCTest

/// Real runs against the installed CLIs, skipped unless ROTA_LIVE=1: each starts
/// a harmless task, sends a message into it while it works, and checks the reply
/// reached the log. They spend a little of each vendor's quota.
final class LiveHarnessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROTA_LIVE"] == "1", "set ROTA_LIVE=1 to run")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rota-live-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func run(_ harness: Harness, prompt: String, message: String?, timeout: TimeInterval = 240,
                     directory: String? = nil, resume: String? = nil,
                     stopAfter: TimeInterval? = nil, model: String? = nil,
                     effort: String? = nil, mode: LaunchMode? = nil) throws -> (RunOutcome, String, String?) {
        let log = folder.appendingPathComponent("\(harness.rawValue).log")
        let workingDirectory = directory ?? folder.path
        let spec = LaunchSpec(executable: harness.defaultExecutable(), prompt: prompt,
                              arguments: harness.arguments(settings: ClaudeUserSettings(), resume: resume),
                              workingDirectory: workingDirectory, environment: [:], mode: mode ?? harness.launchMode,
                              timeout: timeout, log: log, resume: resume, model: model, effort: effort)
        let ended = expectation(description: "run ended")
        // Written by the run's callbacks and read after `wait`, which orders the two.
        nonisolated(unsafe) var outcome: RunOutcome?
        nonisolated(unsafe) var session: String?
        nonisolated(unsafe) var control: RunControl?
        nonisolated(unsafe) var configuration = SessionConfiguration()
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
        }, configuration: { value in
            configuration = value
        })
        control = try ProcessLauncher().launch(spec, events: events)
        wait(for: [ended], timeout: timeout + 30)
        let text = try String(contentsOf: log, encoding: .utf8)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log, shell: harness == .shell, finished: true)
        XCTAssertNil(snapshot.problem, snapshot.problem ?? "")
        XCTAssertEqual(snapshot.structured, harness != .shell)
        if harness.isAgent, harness != .antigravity, outcome == .succeeded {
            XCTAssertNotNil(configuration.model, "The actual runner must report its session model")
            XCTAssertNotNil(configuration.effort, "Every agent must report an explicit resolved effort")
            print("Resolved configuration for \(harness.rawValue): \(configuration)")
            if let effort { XCTAssertEqual(configuration.effort, effort, harness.rawValue) }
        }
        XCTAssertTrue(snapshot.items.contains { $0.kind == .user && $0.text == prompt })
        print("---- \(harness.rawValue) log\n\(text)----")
        if harness == .antigravity, let session { print("Antigravity test session: \(session)") }
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
        XCTAssertTrue(log.lowercased().contains("purple otter\n[rota: completed"), log)
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

    /// Read-only native commands: no model turn, quota use or saved conversation.
    func testAntigravityCatalogSeparatesModelsAndEfforts() throws {
        let executable = Harness.antigravity.defaultExecutable()
        let options = ModelCatalog.models(for: .antigravity, executable: executable)
        XCTAssertFalse(options.isEmpty)
        XCTAssertEqual(Set(options.map(\.id)).count, options.count)
        for option in options {
            let (status, output) = ProcessLauncher.capture(executable,
                ["-p", "/effort", "--model", option.id, "--output-format", "json"],
                in: folder.path, timeout: 20)
            XCTAssertEqual(status, 0, output)
            let native = try XCTUnwrap(AntigravityCatalog.payload(output, command: "effort"))
            let expected = native["adjustable"] as? Bool == true ? native["available"] as? [String] ?? [] : []
            XCTAssertEqual(option.efforts, expected, option.id)
            print("Antigravity catalog: \(option.id) | \(option.title) | \(option.efforts)")
        }
    }

    private func antigravityChoice() throws -> ModelOption {
        let options = ModelCatalog.models(for: .antigravity, executable: Harness.antigravity.defaultExecutable())
        return try XCTUnwrap(options.first { !$0.isDefault && !$0.efforts.isEmpty })
    }

    /// Uses agy's real config commands against a disposable home, never the user's MCP file.
    func testAntigravityMCPRegistrationIsIsolated() throws {
        let home = folder.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("agy-isolated")
        let script = """
        #!/bin/zsh
        export HOME="\(home.path)"
        exec "\(Harness.antigravity.defaultExecutable())" "$@"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let realConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/mcp_config.json")
        let original = try? Data(contentsOf: realConfig)
        defer {
            XCTAssertTrue((try? Data(contentsOf: realConfig)) == original, "The user's MCP config changed")
        }
        XCTAssertFalse(AgentAccess.isAdded(.antigravity, executable: executable.path))
        let (added, output) = ProcessLauncher.capture(executable.path,
            AgentAccess.addArguments(.antigravity, command: "/usr/bin/false"), in: folder.path, timeout: 20)
        XCTAssertEqual(added, 0, output)
        XCTAssertTrue(AgentAccess.isAdded(.antigravity, executable: executable.path))
        let config = try Data(contentsOf: home.appendingPathComponent(".gemini/config/mcp_config.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(Set(servers.keys), ["rota"])
        XCTAssertEqual(servers["rota"]?["command"] as? String, "/usr/bin/false")
        XCTAssertEqual(servers["rota"]?["args"] as? [String], ["mcp"])
        XCTAssertEqual(ProcessLauncher.capture(executable.path, ["mcp", "disable", "rota"],
                                              in: folder.path, timeout: 20).0, 0)
        XCTAssertFalse(AgentAccess.isAdded(.antigravity, executable: executable.path))
        XCTAssertEqual(ProcessLauncher.capture(executable.path, AgentAccess.removeArguments(.antigravity),
                                              in: folder.path, timeout: 20).0, 0)
        XCTAssertFalse(AgentAccess.isAdded(.antigravity, executable: executable.path))
    }

    /// Run only with a development app already serving the explicit disposable data folder.
    /// Read a secret fixture marker through MCP before authorizing a synthetic write.
    func testAntigravityCreatesRoutineOverMCP() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let data = environment["ROTA_DATA_DIR"], let helper = environment["ROTA_MCP_TEST_HELPER"] else {
            throw XCTSkip("Set ROTA_DATA_DIR and ROTA_MCP_TEST_HELPER for an isolated development app")
        }
        let routines = try JSONDecoder().decode([Routine].self,
            from: Data(contentsOf: URL(fileURLWithPath: data).appendingPathComponent("routines.json")))
        let probe = try XCTUnwrap(routines.first { $0.id == "rota-e2e-probe" && !$0.enabled })
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/mcp_config.json")
        let registration = try Data(contentsOf: config)
        let model = try antigravityChoice()
        let (first, _, session) = try run(.antigravity,
            prompt: "Use only the rota MCP get_routine tool to read id rota-e2e-probe. "
                + "Do not call other tools or change anything. Reply with its prompt.",
            message: nil, model: model.id, effort: model.efforts.first)
        XCTAssertEqual(first, .succeeded)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: folder.appendingPathComponent("antigravity.log"), shell: false, finished: true)
        let tools = snapshot.items.filter { $0.kind == .tool }
        let correctTarget = !tools.isEmpty && tools.allSatisfy { $0.text.contains("get_routine") }
            && snapshot.items.contains { $0.kind == .output && $0.text.contains(probe.prompt) }
        XCTAssertTrue(correctTarget, "MCP must return the disposable app's marker before any write")
        let unchanged = try Data(contentsOf: config) == registration
        XCTAssertTrue(unchanged, "The MCP registration changed after checking its target")
        guard first == .succeeded, correctTarget, unchanged else { return }
        let id = try XCTUnwrap(session)
        let (second, log, _) = try run(.antigravity,
            prompt: "Use only rota MCP create_routine once. Set id rota-e2e-created, "
                + "workingDirectory \(folder.path), schedule 0 9 * * 1, harness shell, "
                + "prompt echo synthetic, enabled false. Do not run it. Reply done.",
            message: nil, resume: id, model: model.id, effort: model.efforts.first)
        XCTAssertEqual(second, .succeeded, log)
        let (status, output) = ProcessLauncher.capture(helper, ["show", "rota-e2e-created", "--json"],
                                                       in: folder.path, timeout: 20)
        XCTAssertEqual(status, 0, output)
        let created = try JSONDecoder().decode(Routine.self, from: Data(output.utf8))
        XCTAssertEqual(created.harness, .shell)
        XCTAssertEqual(created.workingDirectory, folder.path)
        XCTAssertFalse(created.enabled)
        XCTAssertEqual(ProcessLauncher.capture(helper, ["remove", "rota-e2e-created"],
                                              in: folder.path, timeout: 20).0, 0)
    }

    func testAntigravityReadsAttachmentOnChosenModel() throws {
        let model = try antigravityChoice()
        let contents = UUID().uuidString
        let source = folder.appendingPathComponent("fixture.txt")
        try contents.write(to: source, atomically: true, encoding: .utf8)
        let attachments = try ChatAttachmentStore(log: folder.appendingPathComponent("antigravity.log")).stage([source])
        try "The original has changed.".write(to: source, atomically: true, encoding: .utf8)
        let prompt = try ChatMessage(text: "Read the attached file. Reply with its contents only. Do not change files.",
                                     attachments: attachments).encoded()
        let (outcome, log, session) = try run(.antigravity, prompt: prompt, message: nil,
                                              model: model.id, effort: model.efforts.first)
        XCTAssertEqual(outcome, .succeeded, log)
        XCTAssertTrue(log.contains(contents), "The agent must read the staged file: \(log)")
        if let session { print("Antigravity attachment test session: \(session)") }
    }

    func testAntigravityTakesAMessageIntoTheSession() throws {
        let model = try antigravityChoice()
        let (outcome, log, session) = try run(.antigravity, prompt: steerable,
                                              message: "Reply with exactly: purple otter",
                                              model: model.id, effort: model.efforts.first)
        XCTAssertEqual(outcome, .succeeded, log)
        XCTAssertNotNil(session)
        XCTAssertTrue(log.contains("[you] Reply with exactly: purple otter"), log)
        XCTAssertTrue(log.lowercased().contains("purple otter\n[rota: completed"), log)
    }

    func testAntigravityContinuesAFinishedSession() throws {
        let model = try antigravityChoice()
        let (first, _, session) = try run(.antigravity,
            prompt: "Do not use tools or change files. "
                + "Reply with exactly these two words, without punctuation: rota test",
            message: nil, model: model.id, effort: model.efforts.first)
        XCTAssertEqual(first, .succeeded)
        guard first == .succeeded else { return }
        let id = try XCTUnwrap(session)
        let (second, log, again) = try run(.antigravity,
            prompt: "What two-word phrase did I ask you to reply with? Reply with that phrase only. Do not use tools.",
            message: nil, resume: id, model: model.id, effort: model.efforts.first)
        XCTAssertEqual(second, .succeeded, log)
        XCTAssertEqual(again, id)
        XCTAssertEqual(log.components(separatedBy: "\nrota test\n").count, 3, log)
        print("Antigravity test session: \(id)")
    }

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
    func testClaudeCodexAndGrokRunOnChosenModels() throws {
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

    func testClaudeResolvesVersionedModelsAndDefaultEffortWithoutATurn() throws {
        let result = try XCTUnwrap(ClaudeConfiguration.read(executable: Harness.claude.defaultExecutable(),
                                                           directory: folder.path))
        XCTAssertNotNil(result.session.effort)
        XCTAssertEqual(result.models.first(where: \.isDefault)?.id, result.session.model)
        XCTAssertTrue(result.models.allSatisfy { $0.id != "opus" && $0.id != "sonnet" && $0.id != "haiku" })
        let override = try XCTUnwrap(ClaudeConfiguration.read(executable: Harness.claude.defaultExecutable(),
            directory: folder.path, model: "haiku", effort: "low"))
        XCTAssertEqual(override.session.effort, "low")
    }

    func testInteractiveClaudeReportsItsResolvedModelAndEffort() throws {
        guard let directory = ProcessInfo.processInfo.environment["ROTA_INTERACTIVE_TEST_DIR"] else {
            throw XCTSkip("Set ROTA_INTERACTIVE_TEST_DIR to a trusted test workspace")
        }
        try XCTSkipUnless(ClaudeUserSettings.read().trusts(directory), "The workspace must already be trusted")
        let (outcome, log, _) = try run(.claude, prompt: "Reply with exactly: ok. Do not run tools or modify files.",
                                        message: nil, directory: directory, mode: .claudeInteractive)
        XCTAssertEqual(outcome, .succeeded, log)
    }

    func testClaudeCodexAndGrokReadAnAttachedFile() throws {
        let source = folder.appendingPathComponent("fixture.txt")
        for harness in [Harness.claude, .codex, .grok] {
            let contents = UUID().uuidString
            try contents.write(to: source, atomically: true, encoding: .utf8)
            let store = ChatAttachmentStore(log: folder.appendingPathComponent("\(harness.rawValue).log"))
            let attachments = try store.stage([source])
            try "The original changed after attaching.".write(to: source, atomically: true, encoding: .utf8)
            let prompt = try ChatMessage(text: "Read the attached file and reply with its contents only.",
                                         attachments: attachments).encoded()
            let (outcome, log, _) = try run(harness, prompt: prompt, message: nil)
            XCTAssertEqual(outcome, .succeeded, log)
            XCTAssertTrue(log.contains(contents), "\(harness.rawValue) must read the staged copy: \(log)")
        }
    }

    /// Each installed terminal Rota knows, and the default, runs the session
    /// script itself; `TERM_PROGRAM` says which one did.
    func testEachInstalledTerminalRunsTheScript() throws {
        let expected: [KnownTerminal: String] = [.terminal: "Apple_Terminal", .iTerm: "iTerm.app", .ghostty: "ghostty"]
        let choices: [KnownTerminal?] = [nil] + TerminalLauncher.installed()
        for terminal in choices {
            let marker = folder.appendingPathComponent("terminal-\(terminal?.rawValue ?? "default")")
            let script = folder.appendingPathComponent("\(terminal?.rawValue ?? "default").command")
            try "#!/bin/zsh\nprint -rn -- \"$TERM_PROGRAM\" > \(shellQuote(marker.path))\nexit 0\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let opened = expectation(description: "opened")
            TerminalLauncher.open(script, in: terminal?.url) { error in
                XCTAssertNil(error)
                opened.fulfill()
            }
            wait(for: [opened], timeout: 15)
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                // iTerm2 asks "OK to run <script>?" unless told to stop asking; answer
                // for this script only, and leave its setting alone.
                Self.confirmITermPrompt(for: script.lastPathComponent)
                Thread.sleep(forTimeInterval: 0.5)
            }
            let ran = try String(contentsOf: marker, encoding: .utf8)
            let handler = try XCTUnwrap(TerminalLauncher.defaultTerminal()
                .flatMap { Bundle(url: $0)?.bundleIdentifier })
            let want = expected[terminal ?? KnownTerminal(rawValue: handler) ?? .terminal]
            print("\(terminal?.title ?? "default") ran the script in \(ran)")
            XCTAssertEqual(ran, want, terminal?.title ?? "default")
        }
    }

    private static func confirmITermPrompt(for name: String) {
        guard let iTerm = NSRunningApplication.runningApplications(withBundleIdentifier: KnownTerminal.iTerm.rawValue)
            .first else { return }
        func value(_ element: AXUIElement, _ key: String) -> AnyObject? {
            var result: CFTypeRef?
            AXUIElementCopyAttributeValue(element, key as CFString, &result)
            return result
        }
        let root = AXUIElementCreateApplication(iTerm.processIdentifier)
        for window in value(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            let parts = value(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard parts.contains(where: { (value($0, kAXValueAttribute) as? String)?.contains(name) == true }),
                  let ok = parts.first(where: { value($0, kAXTitleAttribute) as? String == "OK" }) else { continue }
            AXUIElementPerformAction(ok, kAXPressAction as CFString)
        }
    }

    /// A command that ends at once used to race the poll and read as interrupted.
    func testShellCommandThatFailsAtOnceKeepsItsStatus() throws {
        for _ in 0..<5 {
            let (outcome, log, _) = try run(.shell, prompt: "exit 3", message: nil)
            XCTAssertEqual(outcome, .failed(exitCode: 3), log)
        }
    }
}

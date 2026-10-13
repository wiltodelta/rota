@testable import RotaCore
import XCTest

/// Actual interactive CLI hooks, gated separately from deterministic protocol tests.
final class LiveClaudeHookTests: XCTestCase {
    private var folder: URL!
    private var trusted: String!
    private var helper: String!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROTA_LIVE"] == "1", "set ROTA_LIVE=1 to run")
        trusted = ProcessInfo.processInfo.environment["ROTA_LIVE_TRUSTED_FOLDER"]
            ?? FileManager.default.currentDirectoryPath
        try XCTSkipUnless(ClaudeUserSettings.read().trusts(trusted), "use an already trusted folder")
        helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("RotaCLI").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper))
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rota-hook-live-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    private func launch(prompt: String, permission: Bool = false, cancel: Bool = false) throws -> String {
        let log = folder.appendingPathComponent("interactive.log")
        var program = Harness.claude.defaultExecutable()
        if permission { program = try permissionWrapper(program) }
        let spec = LaunchSpec(executable: program, prompt: prompt, arguments: [], workingDirectory: trusted,
            environment: ["ROTA_CLI": helper, "ROTA_DATA_DIR": folder.path], mode: .claudeInteractive,
            timeout: 120, log: log, model: "haiku", effort: "low")
        let ended = expectation(description: "interactive hook run ended")
        nonisolated(unsafe) var control: RunControl?
        nonisolated(unsafe) var requested = false
        nonisolated(unsafe) var cleared = false
        let events = RunEvents(session: { session in
            LiveSessionManifest.record(session, harness: .claude, cwd: self.trusted, folder: self.folder)
        }, finished: { outcome in
            XCTAssertEqual(outcome, cancel ? .cancelled : .succeeded)
            ended.fulfill()
        }, requests: { requests in
            guard let request = requests.first else { if requested { cleared = true }; return }
            requested = true
            if let manifest = ProcessInfo.processInfo.environment["ROTA_HOOK_LIVE_MANIFEST"],
               let bytes = try? JSONEncoder().encode(request) {
                let name = cancel ? "cancel" : permission ? "permission" : "question"
                let url = URL(fileURLWithPath: manifest).deletingLastPathComponent()
                    .appendingPathComponent(name + "-request.json")
                try? bytes.write(to: url)
            }
            if cancel { control?.stop(); return }
            if permission {
                let expected = #""command":"echo rota-hook-permission-fixture""#
                let matches = request.detail.contains(expected)
                XCTAssertTrue(matches, request.detail)
                control?.respond(request.id, response: .init(choice: matches ? "allow" : "deny"))
                control?.respond(request.id, response: .init(choice: "deny"))
            } else {
                XCTAssertFalse(request.questions.isEmpty)
                XCTAssertTrue(request.questions.allSatisfy(\.multiple))
                guard !request.questions.isEmpty else { control?.stop(); return }
                let answers = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, "Summary, Details") })
                control?.respond(request.id, response: .init(choice: "submit", answers: answers))
            }
        })
        control = try ProcessLauncher().launch(spec, events: events)
        wait(for: [ended], timeout: 150)
        XCTAssertTrue(requested, "the real interactive CLI must surface a chat form")
        XCTAssertTrue(cleared, "the form must be removed after response or cancellation")
        let text = try String(contentsOf: log, encoding: .utf8)
        print("---- Interactive Claude hook log\n" + text)
        return text
    }

    private func permissionWrapper(_ executable: String) throws -> String {
        let wrapper = folder.appendingPathComponent("force-permission.py")
        let code = """
            #!/usr/bin/python3
            import json, os, sys
            args = sys.argv[1:]
            settings_path = args[args.index('--settings') + 1]
            with open(settings_path) as stream:
                settings = json.load(stream)
            settings['permissions'] = {'ask': ['Bash']}
            with open(settings_path, 'w') as stream:
                json.dump(settings, stream)
            program = \(try pythonLiteral(executable))
            os.execv(program, [program, '--permission-mode', 'manual'] + args)
            """
        try code.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        return wrapper.path
    }

    private func pythonLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value,
                                              options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return lossyUTF8(data)
    }

    func testInteractiveQuestionAnswersComeFromTheChat() throws {
        let text = try launch(prompt: "Use AskUserQuestion with one multiSelect question, exactly Summary and Details "
            + "options. After I answer, repeat both selected labels in your final answer. Do not use any other tools.")
        let reader = SessionEventReader()
        _ = try reader.read(from: SessionEventReader.file(for: folder.appendingPathComponent("interactive.log")))
        let answer = try XCTUnwrap(reader.transcript.items.last { $0.kind == .agent }).text
        XCTAssertTrue(answer.contains("Summary") && answer.contains("Details"), text)
        let tool = try XCTUnwrap(reader.transcript.items.first { $0.kind == .tool })
        XCTAssertTrue(tool.tool?.output?.contains("Summary, Details") == true,
                      "the actual tool result must carry the chat answer, not just the model's text")
    }

    func testInteractivePermissionIsAnsweredOnceThroughTheChat() throws {
        let text = try launch(prompt: "Run only the shell command echo rota-hook-permission-fixture, then reply done.",
                              permission: true)
        XCTAssertTrue(text.contains("rota-hook-permission-fixture"), text)
    }

    func testStoppingAnInteractiveQuestionCancelsTheForm() throws {
        _ = try launch(prompt: "Use AskUserQuestion to ask which output I prefer, exactly Summary and Details options.",
                       cancel: true)
    }
}

import Foundation
@testable import RotaCore
import XCTest

final class SessionArchiveTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rota-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func resume(adopt: Bool = false, unarchiveFails: Bool = false,
                        unavailable: Bool = false) throws -> [String] {
        let root = try folder()
        let log = root.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let ended = expectation(description: "native run ended")
        let journal = RunJournal(output: try FileHandle(forWritingTo: log), events: RunEvents(
            session: { _ in }, finished: { _ in ended.fulfill() }))
        var spec = LaunchSpec(executable: "/bin/false", prompt: "Continue", arguments: [],
                              workingDirectory: root.path, environment: [:], mode: .codexDaemon,
                              timeout: nil, log: log, resume: "thread")
        spec.adopt = adopt
        let transport = HarnessPeer()
        let run = CodexDaemonRun(spec: spec, journal: journal, peer: JSONRPCPeer(transport: transport))
        var requests: [String] = []
        var restored = false
        transport.receive = { request in
            guard let method = request["method"] as? String, method != "initialized" else { return }
            requests.append(method)
            switch method {
            case "thread/resume":
                if unavailable { return transport.reply(request, error: "Service unavailable") }
                if !restored {
                    return transport.reply(request, error: "session thread is archived. Run codex unarchive.")
                }
                transport.reply(request, result: ["thread": ["id": "thread", "status": ["type": "idle"]]])
            case "thread/unarchive":
                XCTAssertFalse(adopt, "recovery must not restore an archive")
                if unarchiveFails { return transport.reply(request, error: "Restore unavailable") }
                restored = true
                transport.reply(request)
            case "thread/turns/list": transport.reply(request, result: ["data": []])
            case "turn/start":
                transport.reply(request, result: ["turn": ["id": "turn"]])
                run.handle("turn/completed", ["threadId": "thread", "turn": ["id": "turn", "status": "completed"]])
            default: XCTFail("Unexpected method: " + method)
            }
        }
        run.initialized(.success([:]))
        wait(for: [ended], timeout: 3)
        return requests
    }

    func testExplicitContinuationRestoresTheArchiveThroughCodex() throws {
        XCTAssertEqual(try resume(),
                       ["thread/resume", "thread/unarchive", "thread/resume", "thread/turns/list", "turn/start"])
    }

    func testRecoveryAndUnavailableServiceNeverUnarchiveOrStartATurn() throws {
        XCTAssertEqual(try resume(adopt: true), ["thread/resume"])
        XCTAssertEqual(try resume(unavailable: true), ["thread/resume"])
        XCTAssertEqual(try resume(unarchiveFails: true), ["thread/resume", "thread/unarchive"])
    }

    func testTerminalRestoresBeforeResumeAndStopsIfRestoreFails() throws {
        for status in [0, 17] {
            let root = try folder()
            let cli = root.appendingPathComponent("codex-stub")
            let calls = root.appendingPathComponent("calls")
            try """
            #!/bin/zsh
            print -r -- "$*" >> \(shellQuote(calls.path))
            if [[ "$1" == unarchive ]]; then exit \(status); fi
            """.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            var spec = LaunchSpec(executable: cli.path, prompt: "", arguments: ["resume", "thread"],
                                  workingDirectory: root.path, environment: [:], mode: .terminal(.codex),
                                  timeout: nil, log: root.appendingPathComponent("session.log"), resume: "thread")
            spec.terminalTranscript = root.appendingPathComponent("archived_sessions/rollout-thread.jsonl.zst")
            let script = root.appendingPathComponent("terminal.zsh")
            let exitFile = root.appendingPathComponent("exit")
            try TerminalRun.scriptText(spec, exitFile: exitFile, childFile: root.appendingPathComponent("pid"))
                .write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(try String(contentsOf: exitFile, encoding: .utf8), "\(status)\n")
            XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8),
                           status == 0 ? "unarchive thread\nresume thread\n" : "unarchive thread\n")
        }
    }

    func testUncompressedArchiveFollowsItsNativeMoveWithoutReplayingHistory() throws {
        let home = try folder()
        let id = UUID().uuidString.lowercased()
        let archive = home.appendingPathComponent(".codex/archived_sessions/rollout-\(id).jsonl")
        let active = home.appendingPathComponent(".codex/sessions/rollout-\(id).jsonl")
        for url in [archive, active] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        try Data("{\"type\":\"session_meta\"}\n".utf8).write(to: archive)
        var reader = try NativeTranscript(url: archive, harness: .codex, home: home)
        try FileManager.default.moveItem(at: archive, to: active)
        let file = try FileHandle(forWritingTo: active)
        try file.seekToEnd()
        let row = #"""
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"New answer"}]}}
        """#
        try file.write(contentsOf: Data(row.utf8) + Data([10]))
        try file.close()
        XCTAssertEqual(try reader.read(), [.item(.agent, "New answer")])
    }
}

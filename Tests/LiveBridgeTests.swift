import Darwin
import Foundation
@testable import RotaCore
import XCTest

/// Verify the environment of the actual MCP child, not the model's explanation of it.
final class LiveBridgeTests: XCTestCase {
    private var folder: URL!
    private var nativeSessions: [(Harness, String)] = []
    private var leaderSocket: URL?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROTA_LIVE"] == "1")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-live-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let folder else { return }
        // The leader is isolated by this test's unique socket. Never stop the user's shared leader.
        let processes = ProcessLauncher.capture("/bin/ps", ["-axo", "pid=,command="], in: folder.path,
                                                timeout: 5, loginShell: false).1
        for line in processes.split(separator: "\n")
            where leaderSocket.map({ line.contains($0.path) }) == true && line.contains("agent leader") {
            if let pid = line.split(whereSeparator: \.isWhitespace).first.flatMap({ Int32($0) }),
               let owned = OwnedProcess(pid: pid) {
                for child in owned.descendants() { child.signal(SIGTERM) }
                owned.signal(SIGTERM)
            }
        }
        if let socket = leaderSocket {
            for suffix in ["", ".daemon", ".pid", ".lock"] {
                try? FileManager.default.removeItem(atPath: socket.path + suffix)
            }
        }
        for (harness, session) in nativeSessions {
            print("Bridge test native session: \(harness.rawValue) \(session)")
        }
        try? FileManager.default.removeItem(at: folder)
    }

    func testCodexMCPReceivesItsThreadsEnvironment() throws { try check(.codex, model: "gpt-6-luna") }
    func testGrokMCPReceivesItsSessionsEnvironment() throws { try check(.grok, model: "grok-4.6") }

    private func check(_ harness: Harness, model: String) throws {
        let cli = folder.appendingPathComponent("agent")
        let helper = folder.appendingPathComponent("mcp-identity")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/session-mcp.py")
        try FileManager.default.copyItem(at: source, to: helper)
        let socket = URL(fileURLWithPath: "/tmp").appendingPathComponent(folder.lastPathComponent + ".sock")
        if harness == .grok { leaderSocket = socket }
        let command = harness == .grok
            ? [harness.defaultExecutable(), "--leader-socket", socket.path] : [harness.defaultExecutable()]
        let script = "#!/bin/zsh\n"
            + "if [[ $1 == mcp ]]; then echo '{\"rota\":{}}'; exit 0; fi\n"
            + "exec " + command.map(shellQuote).joined(separator: " ") + " \"$@\"\n"
        try script.write(to: cli, atomically: true, encoding: .utf8)
        for file in [cli, helper] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let token = UUID().uuidString
        let audit = folder.appendingPathComponent("mcp-calls.jsonl")
        let spec = LaunchSpec(executable: cli.path,
            prompt: "Call the rota MCP server's identity tool once. "
                + "Reply only with its result. Do not use any other tools.",
            arguments: [], workingDirectory: folder.path,
            environment: ["ROTA_SESSION": token, "ROTA_ROUTINE": "synthetic", "ROTA_CLI": helper.path,
                          "ROTA_BRIDGE_AUDIT": audit.path], mode: harness.launchMode, timeout: 120,
            log: folder.appendingPathComponent("session.log"), model: model, effort: "low")
        let ended = expectation(description: "native MCP identity")
        let control = try ProcessLauncher().launch(spec, events: RunEvents(session: {
            self.nativeSessions.append((harness, $0))
        }, finished: {
            XCTAssertEqual($0, .succeeded)
            ended.fulfill()
        }))
        wait(for: [ended], timeout: 150)
        withExtendedLifetime(control) {}
        guard FileManager.default.fileExists(atPath: audit.path) else {
            let log = try String(contentsOf: spec.log, encoding: .utf8)
            return XCTFail("The native MCP tool was not called: \(log)")
        }
        let rows = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        XCTAssertFalse(rows.isEmpty, "The model must call the real synthetic MCP tool")
        XCTAssertTrue(rows.allSatisfy { $0?["session"] as? String == token }, "Every MCP child must be session-scoped")
    }
}

import Darwin
import Foundation
@testable import RotaCore
import XCTest

/// Losing only the client reproduces a host interruption while the native service stays alive.
final class LiveRecoveryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROTA_LIVE"] == "1")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rota-live-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    func testCodexReconcilesTheNativeTurnWithoutStartingAnother() throws { try recover(.codex, model: "gpt-6-luna") }
    func testGrokReconcilesTheNativePromptWithoutStartingAnother() throws { try recover(.grok, model: "grok-4.6") }

    private func recover(_ harness: Harness, model: String) throws {
        let proof = "RECOVERED-" + UUID().uuidString.prefix(6)
        let log = folder.appendingPathComponent("session.log")
        var spec = LaunchSpec(executable: harness.defaultExecutable(),
            prompt: "Run the terminal command sleep 15 synchronously, then reply exactly \(proof). "
                + "Do not change files.",
            arguments: [], workingDirectory: folder.path, environment: [:], mode: harness.launchMode,
            timeout: 90, log: log, model: model, effort: "low")
        let disconnected = expectation(description: "original client disconnected")
        nonisolated(unsafe) var session: String?
        nonisolated(unsafe) var original: RunControl?
        original = try ProcessLauncher().launch(spec, events: RunEvents(session: { id in
            session = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                (original as? CodexDaemonRun)?.disconnect()
                (original as? GrokACPRun)?.disconnect()
            }
        }, finished: { _ in disconnected.fulfill() }))
        wait(for: [disconnected], timeout: 30)
        let id = try XCTUnwrap(session)
        print("Recovery test native session: \(harness.rawValue) \(id)")
        spec.resume = id
        spec.prompt = ""
        spec.adopt = true
        let ended = expectation(description: "native state reconciled")
        nonisolated(unsafe) var outcome: RunOutcome?
        let restored = try ProcessLauncher().launch(spec, events: RunEvents(
            session: { XCTAssertEqual($0, id) }, finished: {
            outcome = $0
            ended.fulfill()
        }))
        wait(for: [ended], timeout: 120)
        withExtendedLifetime((original, restored)) {}
        XCTAssertTrue(outcome == .succeeded || outcome == .cancelled,
                      "Native outcome must be established: \(String(describing: outcome))")
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log, finished: true)
        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(snapshot.items.filter { $0.kind == .user }.count, 1, "Recovery must not submit Continue")
        if outcome == .succeeded {
            XCTAssertEqual(snapshot.items.filter { $0.kind == .agent && $0.text.contains(proof) }.count, 1)
        }
    }

    func testShellStopWaitsForAnIgnoringDescendantToDie() throws {
        let pidFile = folder.appendingPathComponent("child.pid")
        let body = "trap '' HUP TERM; echo $$ > \(shellQuote(pidFile.path)); exec /bin/sleep 300"
        let spec = LaunchSpec(executable: "/bin/zsh", prompt: "/bin/sh -c " + shellQuote(body), arguments: [],
            workingDirectory: folder.path, environment: [:], mode: .screen, timeout: 15,
            log: folder.appendingPathComponent("shell.log"))
        let ended = expectation(description: "owned process tree stopped")
        nonisolated(unsafe) var control: RunControl?
        nonisolated(unsafe) var child: OwnedProcess?
        func stopWhenReady() {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               let owned = OwnedProcess(pid: pid) {
                child = owned
                control?.stop()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { stopWhenReady() }
            }
        }
        defer { child?.signal(SIGKILL) }
        control = try ProcessLauncher().launch(spec, events: RunEvents(session: { _ in stopWhenReady() }, finished: {
            XCTAssertEqual($0, .cancelled)
            XCTAssertFalse(child?.exists ?? false, "Stopped means the owned descendant has actually exited")
            ended.fulfill()
        }))
        wait(for: [ended], timeout: 20)
        withExtendedLifetime(control) {}
    }
}

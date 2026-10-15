@testable import RotaCore
import XCTest

/// Fake only the provider boundary; the real launcher, transport, runner and journal remain in use.
final class ProviderProtocolTests: XCTestCase {
    private func run(malformed: Bool) throws -> (RunOutcome, [TranscriptItem]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let program = folder.appendingPathComponent("provider.py")
        let script = """
            #!/usr/bin/python3
            import json, sys
            malformed = \(malformed ? "True" : "False")
            def emit(value):
                print(json.dumps(value), flush=True)
            for line in sys.stdin:
                request = json.loads(line)
                method = request.get('method')
                if method == 'initialize':
                    result = {'protocolVersion': 1, 'agentCapabilities': {}}
                elif method == 'session/new':
                    result = {} if malformed else {'sessionId': 'fixture-session'}
                elif method == 'session/prompt':
                    for session, text in [('other-session', 'Foreign content'),
                                          ('fixture-session', 'Expected content')]:
                        emit({'jsonrpc': '2.0', 'method': 'session/update', 'params': {
                            'sessionId': session, 'update': {'sessionUpdate': 'agent_message_chunk',
                                'content': {'type': 'text', 'text': text}}}})
                    result = {'stopReason': 'end_turn'}
                else:
                    continue
                emit({'jsonrpc': '2.0', 'id': request['id'], 'result': result})
            """
        try script.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let log = folder.appendingPathComponent("session.log")
        let spec = LaunchSpec(executable: program.path, prompt: "Read the fixture", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .grokACP,
                              timeout: nil, log: log)
        let ended = expectation(description: "provider response processed")
        nonisolated(unsafe) var outcome: RunOutcome?
        let control = try ProcessLauncher().launch(spec, events: RunEvents(session: { _ in }, finished: {
            outcome = $0
            ended.fulfill()
        }))
        defer { control.stop() }
        wait(for: [ended], timeout: 10)
        let reader = SessionEventReader()
        XCTAssertTrue(try reader.read(from: SessionEventReader.file(for: log)))
        return (try XCTUnwrap(outcome), reader.transcript.items)
    }

    func testMalformedSuccessEndsAsALaunchFailure() throws {
        let (outcome, _) = try run(malformed: true)
        guard case .launchFailed(let reason) = outcome else { return XCTFail("Expected a launch failure: \(outcome)") }
        XCTAssertTrue(reason.contains("session/new"))
        XCTAssertTrue(reason.contains("invalid response"))
    }

    func testForeignSessionUpdatesCannotReachTheConversation() throws {
        let (outcome, items) = try run(malformed: false)
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(items.filter { $0.kind == .agent }.map(\.text), ["Expected content"])
    }
}

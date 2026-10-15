@testable import RotaCore
import XCTest

/// Exercise the real Codex runner and WebSocket transport against a controlled provider boundary.
final class CodexProtocolTests: XCTestCase {
    func testStopBeforeTheTurnAcknowledgmentInterruptsTheAcceptedTurn() throws {
        try stoppedTurn(notifiesStart: false)
    }

    func testStopConsumesTheTurnNotificationAndReplyWithoutInterruptingTwice() throws {
        try stoppedTurn(notifiesStart: true)
    }

    private func stoppedTurn(notifiesStart: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = folder.appendingPathComponent("release-reply")
        let trace = folder.appendingPathComponent("requests.jsonl")
        let finished = folder.appendingPathComponent("provider-finished")
        let program = folder.appendingPathComponent("provider.py")
        try provider(gate: gate, trace: trace, finished: finished, notifiesStart: notifiesStart)
            .write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let spec = LaunchSpec(executable: program.path, prompt: "Read the fixture", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .codexDaemon,
                              timeout: nil, log: folder.appendingPathComponent("session.log"))
        let ended = expectation(description: "the stopped run finishes")
        let providerEnded = expectation(description: "the provider received the final protocol messages")
        nonisolated(unsafe) var outcome: RunOutcome?
        nonisolated(unsafe) var control: RunControl?
        control = try ProcessLauncher().launch(spec, events: RunEvents(session: { id in
            XCTAssertEqual(id, "fixture-thread")
            control?.stop()
            try? Data().write(to: gate)
        }, finished: {
            outcome = $0
            ended.fulfill()
        }))
        defer { control?.stop() }
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: finished.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            providerEnded.fulfill()
        }
        wait(for: [ended, providerEnded], timeout: 7)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
        let requests = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:]
        }
        XCTAssertTrue(requests.contains { $0["method"] as? String == "turn/start" })
        let interrupt = try XCTUnwrap(requests.first { $0["method"] as? String == "turn/interrupt" })
        XCTAssertEqual(requests.filter { $0["method"] as? String == "turn/interrupt" }.count, 1)
        XCTAssertEqual(interrupt["params"] as? [String: String],
                       ["threadId": "fixture-thread", "turnId": "fixture-turn"])
    }

    private func provider(gate: URL, trace: URL, finished: URL, notifiesStart: Bool) -> String {
        """
        #!/usr/bin/python3
        import base64, hashlib, json, os, signal, struct, sys, time
        if 'daemon' in sys.argv:
            sys.exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        source, output = sys.stdin.buffer, sys.stdout.buffer
        def exact(count):
            data = b''
            while len(data) < count:
                chunk = source.read(count - len(data))
                if not chunk:
                    raise EOFError()
                data += chunk
            return data
        def emit(value):
            payload = json.dumps(value).encode()
            header = bytes([0x81, len(payload)]) if len(payload) < 126 else b'\\x81\\x7e' + struct.pack('!H', len(payload))
            output.write(header + payload)
            output.flush()
        head = b''
        while not head.endswith(b'\\r\\n\\r\\n'):
            head += exact(1)
        key = next(line.split(':', 1)[1].strip() for line in head.decode().splitlines()
                   if line.lower().startswith('sec-websocket-key:'))
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        output.write(('HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n'
                      + 'Sec-WebSocket-Accept: ' + accept + '\\r\\n\\r\\n').encode())
        output.flush()
        """ + "\n" + providerReplies(gate: gate, trace: trace, finished: finished, notifiesStart: notifiesStart)
    }

    private func providerReplies(gate: URL, trace: URL, finished: URL, notifiesStart: Bool) -> String {
        """
        try:
            while True:
                header = exact(2)
                size = header[1] & 127
                if size == 126:
                    size = struct.unpack('!H', exact(2))[0]
                elif size == 127:
                    size = struct.unpack('!Q', exact(8))[0]
                mask = exact(4) if header[1] & 128 else None
                payload = exact(size)
                if mask:
                    payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
                if header[0] & 15 == 8:
                    break
                request = json.loads(payload)
                with open('\(trace.path)', 'a') as log:
                    log.write(json.dumps(request) + '\\n')
                method = request.get('method')
                if method == 'initialized':
                    continue
                if method == 'thread/start':
                    result = {'thread': {'id': 'fixture-thread'}}
                elif method == 'turn/start':
                    while not os.path.exists('\(gate.path)'):
                        time.sleep(0.01)
                    if \(notifiesStart ? "True" : "False"):
                        emit({'jsonrpc': '2.0', 'method': 'turn/started', 'params': {'threadId': 'fixture-thread',
                              'turn': {'id': 'fixture-turn'}}})
                    result = {'turn': {'id': 'fixture-turn'}}
                else:
                    result = {}
                emit({'jsonrpc': '2.0', 'id': request['id'], 'result': result})
                if method == 'turn/interrupt':
                    emit({'jsonrpc': '2.0', 'method': 'turn/completed', 'params': {'threadId': 'fixture-thread',
                          'turn': {'id': 'fixture-turn', 'status': 'interrupted'}}})
        except (EOFError, BrokenPipeError):
            pass
        finally:
            with open('\(finished.path)', 'w') as flag:
                flag.write('finished')
        """
    }
}

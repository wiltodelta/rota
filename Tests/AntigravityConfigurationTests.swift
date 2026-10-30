@testable import RotaCore
import XCTest

final class AntigravityConfigurationTests: XCTestCase {
    func testRunnerResolvesAndPinsDefaultBeforeSendingPrompt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-model-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("agy")
        let script = """
        #!/bin/zsh
        [[ "$ROTA_MODEL_FIXTURE" == resolved ]] || exit 7
        if [[ "$1" == -p ]]; then
            [[ "$2" == /model && "$*" == *'--conversation fixture-session'* ]] || exit 8
            printf '%s' '{"status":"SUCCESS","command":{"name":"model","data":{"id":"fixture-v2-high","label":"Fixture V2 (High)","effort":"high"}}}'
            exit 0
        fi
        [[ "$*" == *'--model fixture-v2-high'* ]] || exit 9
        IFS= read -r message
        [[ "$message" == *'Synthetic prompt'* ]] || exit 10
        printf '%s\\n' '{"event":"init","conversation_id":"fixture-session","init":{}}'
        printf '%s\\n' '{"event":"result","result":{"status":"SUCCESS","response":"Done"}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let spec = LaunchSpec(executable: executable.path, prompt: "Synthetic prompt", arguments: [],
                              workingDirectory: folder.path, environment: ["ROTA_MODEL_FIXTURE": "resolved"],
                              mode: .antigravityStream, timeout: 10, log: folder.appendingPathComponent("run.log"),
                              resume: "fixture-session")
        let finished = expectation(description: "runner finished")
        var configuration = SessionConfiguration()
        let control = try ProcessLauncher().launch(spec, events: RunEvents(session: { _ in }, finished: {
            XCTAssertEqual($0, .succeeded)
            finished.fulfill()
        }, configuration: { configuration = $0 }))
        wait(for: [finished], timeout: 15)
        withExtendedLifetime(control) {}
        XCTAssertEqual(configuration, SessionConfiguration(model: "fixture-v2-high", effort: "high",
                                                         modelTitle: "Fixture V2"))
        XCTAssertEqual(SessionConfiguration.recordedModel(log: spec.log), "fixture-v2-high")
    }
}

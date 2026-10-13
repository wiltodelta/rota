@testable import RotaCore
import XCTest

final class HarnessConfigurationTests: XCTestCase {
    private func spec(resume: String? = nil, model: String? = nil, effort: String? = nil) -> LaunchSpec {
        LaunchSpec(executable: "/bin/echo", prompt: "Check the report", arguments: [], workingDirectory: "/tmp",
                   environment: ["ROTA_SESSION": "session-1"], mode: .codexDaemon, timeout: nil,
                   log: URL(fileURLWithPath: "/tmp/unused-rota-log"), resume: resume, model: model, effort: effort)
    }

    func testCodexStartAndResumeKeepConfiguredPermissionsAndDefaultModel() throws {
        for resume in [String?.none, "thread-1"] {
            let params = CodexDaemonRun.threadParameters(spec(resume: resume))
            XCTAssertEqual(params["cwd"] as? String, "/tmp")
            XCTAssertEqual(params["threadId"] as? String, resume)
            XCTAssertNil(params["approvalPolicy"])
            XCTAssertNil(params["sandbox"])
            XCTAssertNil(params["model"])
            let config = try XCTUnwrap(params["config"] as? [String: String])
            XCTAssertEqual(config, ["shell_environment_policy.set.ROTA_SESSION": "session-1"])
        }
    }

    func testExplicitModelIsTheOnlyCodexModelOverride() {
        XCTAssertEqual(CodexDaemonRun.threadParameters(spec(model: "selected-model"))["model"] as? String,
                       "selected-model")
    }

    func testGrokUsesConfiguredPermissionsAndModelUnlessSelected() {
        XCTAssertEqual(GrokACPRun.arguments(spec()), ["agent", "--leader", "stdio"])
        XCTAssertEqual(GrokACPRun.arguments(spec(model: "selected-model", effort: "high")),
                       ["agent", "--leader", "--model", "selected-model", "--reasoning-effort", "high", "stdio"])
    }
}

@testable import RotaCore
import XCTest

final class ClaudeConfigurationTests: XCTestCase {
    func testAppliedControlReplyUsesTheEffectiveLevelAndExplicitAbsence() throws {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: ClaudeConfiguration.request(
            "get_settings", id: ClaudeConfiguration.settingsID)) as? [String: Any])
        XCTAssertEqual(request["type"] as? String, "control_request")
        XCTAssertEqual((request["request"] as? [String: String])?["subtype"], "get_settings")
        func response(_ effort: Any) -> [String: Any] {
            ["type": "control_response", "response": ["request_id": ClaudeConfiguration.settingsID,
                "subtype": "success", "response": ["applied": ["model": "fixture-1.2", "effort": effort]]]]
        }
        XCTAssertEqual(ClaudeConfiguration.applied(response("low")),
                       SessionConfiguration(model: "fixture-1.2", effort: "low"))
        XCTAssertEqual(ClaudeConfiguration.applied(response(NSNull()))?.effort, "none")
        var unrelated = response("low")
        unrelated["type"] = "assistant"
        XCTAssertNil(ClaudeConfiguration.applied(unrelated))
        XCTAssertNil(ClaudeConfiguration.applied(["type": "control_response", "response": ["subtype": "error"]]))
    }

    func testReadConsumesControlRepliesBeforeEOFWithoutSendingAPrompt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("claude-fixture")
        let script = """
        #!/bin/zsh
        read -r initialize
        read -r settings
        [[ "$initialize" == *rota-initialize* && "$settings" == *rota-settings* ]] || exit 2
        echo '{"type":"control_response","response":{"request_id":"rota-initialize","subtype":"success",        "response":{"models":[{"value":"family","resolvedModel":"fixture-1.2","displayName":"Fixture 1.2"}]}}}'
        echo '{"type":"control_response","response":{"request_id":"rota-settings","subtype":"success",        "response":{"applied":{"model":"fixture-1.2","effort":"high"}}}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let result = try XCTUnwrap(ClaudeConfiguration.read(executable: executable.path, directory: folder.path))
        XCTAssertEqual(result.session, SessionConfiguration(model: "fixture-1.2", effort: "high"))
        XCTAssertEqual(result.models.map(\.id), ["fixture-1.2"])
    }

    func testCatalogUsesResolvedIDsDeduplicatesAliasesAndPreservesCapabilities() {
        let rows: [[String: Any]] = [
            ["value": "default", "resolvedModel": "fixture-1.2", "displayName": "Default"],
            ["value": "family", "resolvedModel": "fixture-1.2", "displayName": "Fixture 1.2",
             "supportedEffortLevels": ["low", "high"]],
            ["value": "fixture-1.2", "resolvedModel": "fixture-1.2", "displayName": "Fixture 1.2"],
            ["value": "older", "resolvedModel": "fixture-1.1", "displayName": "Fixture 1.1"],
            ["value": "unresolved", "displayName": "No version"]
        ]
        let models = ModelCatalog.parseClaudeModels(["models": rows])
        XCTAssertEqual(models.map(\.id), ["fixture-1.2", "fixture-1.1"])
        XCTAssertEqual(models.map(\.title), ["Fixture 1.2", "Fixture 1.1"])
        XCTAssertEqual(models[0].efforts, ["low", "high"])
        XCTAssertTrue(models[0].isDefault)
        XCTAssertTrue(models[0].matches("family"))
        XCTAssertFalse(models[0].matches(nil))
        XCTAssertFalse(models[0].matches("older"))
        XCTAssertTrue(models[1].efforts.isEmpty, "A model without effort must not borrow another model's levels")
    }
}

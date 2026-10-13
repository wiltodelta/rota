import Foundation
import XCTest
@testable import RotaCore

final class ClaudeModelCatalogTests: XCTestCase {
    func testUnavailableHarnessDoesNotInventChoices() {
        XCTAssertTrue(ModelCatalog.models(for: .claude, executable: "/nonexistent/claude").isEmpty)
    }
    // Shape read from Claude Code's initialize control response. No prompt is sent.
    func testVersionsPreserveAliasIDsAndProviderDefault() {
        let models = ModelCatalog.parseClaudeModels(["models": [
            ["value": "default", "resolvedModel": "claude-opus-5-5", "displayName": "Default (recommended)"],
            ["value": "opus", "resolvedModel": "claude-opus-5-5", "displayName": "Opus 5.5",
             "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]],
            ["value": "claude-opus-4-6", "resolvedModel": "claude-opus-4-6", "displayName": "Opus 4.6",
             "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "max"]],
            ["value": "haiku", "resolvedModel": "claude-haiku-5-5", "displayName": "Haiku 5.5",
             "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]],
            ["value": "claude-haiku-4-5-20251001", "resolvedModel": "claude-haiku-4-5-20251001",
             "displayName": "Haiku 4.5"]
        ]])
        XCTAssertEqual(models.map(\.id), ["opus", "claude-opus-4-6", "haiku", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(models.map(\.title), ["Opus 5.5", "Opus 4.6", "Haiku 5.5", "Haiku 4.5"])
        XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["opus"])
        XCTAssertTrue(models[0].efforts.contains("xhigh"))
        XCTAssertFalse(models[1].efforts.contains("xhigh"))
        XCTAssertTrue(models[2].efforts.contains("xhigh"))
        XCTAssertTrue(models[3].efforts.isEmpty)
    }

    func testControlHandshakeWithoutPrompt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude-fixture")
        let script = """
        #!/usr/bin/python3
        import json, sys
        request = json.loads(sys.stdin.readline())
        assert request['type'] == 'control_request'
        assert request['request'] == {'subtype': 'initialize', 'hooks': None}
        assert '--no-session-persistence' in sys.argv
        assert '{"disableAllHooks":true}' in sys.argv
        response = {'models': [{'value': 'opus', 'displayName': 'Opus 5.5', 'resolvedModel': 'claude-opus-5-5'}]}
        # An unrelated response must not release the caller.
        print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success',
              'request_id': 'unrelated', 'response': {'models': []}}}), flush=True)
        print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success',
              'request_id': request['request_id'], 'response': response}}), flush=True)
        sys.stdin.read()
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let models = ModelCatalog.claudeModels(executable: executable.path)
        XCTAssertEqual(models.map(\.title), ["Opus 5.5"])
        XCTAssertEqual(models.map(\.id), ["opus"])
    }
}

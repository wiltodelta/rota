import Foundation
@testable import RotaCore
import XCTest

/// Local protocol checks never start a model turn or alter a CLI configuration.
final class InstalledHarnessContractTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func executable(_ harness: Harness) throws -> String {
        let domain = ProcessInfo.processInfo.environment["ROTA_BUNDLE_ID"] ?? "com.wiltodelta.rota"
        let chosen = UserDefaults(suiteName: domain)?.dictionary(forKey: "executables")?[harness.rawValue] as? String
        let path = chosen.flatMap { $0.isEmpty ? nil : $0 }
            ?? ExecutableDiscovery.installedAgents()[harness]?.first?.path ?? harness.defaultExecutable()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: path),
                          "Install \(harness.title) to check its contract")
        return path
    }

    func testInstalledCodexInteractionSchemaMatchesAdapters() throws {
        let schema = folder.appendingPathComponent("schema")
        let (status, output) = ProcessLauncher.capture(try executable(.codex),
            ["app-server", "generate-json-schema", "--experimental", "--out", schema.path], in: folder.path)
        XCTAssertEqual(status, 0, output)
        let data = try Data(contentsOf: schema.appendingPathComponent("ServerRequest.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variants = try XCTUnwrap(root["oneOf"] as? [[String: Any]])
        var checked: [String] = []
        for variant in variants {
            let properties = variant["properties"] as? [String: Any]
            let method = (properties?["method"] as? [String: Any])?["enum"] as? [String]
            guard let method = method?.first,
                  method.contains("Approval") || method.contains("requestUserInput") || method.contains("elicitation")
            else { continue }
            XCTAssertNotNil(QuestionRequest.codex(method, [:]), method)
            checked.append(method)
        }
        XCTAssertFalse(checked.isEmpty, "The schema walk must reach interaction requests")
        print("Codex interaction methods checked: \(checked.sorted())")
    }

    private func flags(_ harness: Harness, arguments: [String] = ["--help"], required: [String]) throws {
        let path = try executable(harness)
        print("Installed \(harness.title): \(ExecutableDiscovery.version(of: path) ?? "version unreported")")
        let result = ProcessLauncher.capture(path, arguments, in: folder.path, timeout: 15)
        XCTAssertEqual(result.0, 0, result.1)
        for flag in required { XCTAssertTrue(result.1.contains(flag), "Missing \(harness.title) contract: \(flag)") }
    }

    func testClaudeFlags() throws {
        try flags(.claude, required: ["--input-format", "--output-format", "--include-partial-messages",
                                     "--resume", "--permission-mode", "--settings", "--effort"])
    }

    func testCodexDaemonFlags() throws {
        try flags(.codex, arguments: ["app-server", "--help"], required: ["daemon", "proxy", "generate-json-schema"])
    }

    func testGrokACPFlags() throws {
        try flags(.grok, arguments: ["agent", "--help"],
                  required: ["--leader", "--no-leader", "--reasoning-effort", "stdio"])
    }

    func testAntigravityFlags() throws {
        try flags(.antigravity, required: ["--input-format", "--output-format", "--conversation", "--effort"])
    }

    func testInstalledModelMetadataWithoutGeneration() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROTA_PROTOCOL_CHECK"] == "1",
                          "Set ROTA_PROTOCOL_CHECK=1 for account-backed metadata reads without generation")
        for harness in Harness.agents {
            let path = try executable(harness)
            let models: [ModelOption]
            if harness == .antigravity {
                let result = AntigravityCatalog.readResult(executable: path)
                XCTAssertTrue(result.complete, "Some Antigravity model families could not be verified")
                models = result.models
            } else { models = ModelCatalog.models(for: harness, executable: path) }
            XCTAssertFalse(models.isEmpty, "\(harness.title) metadata unavailable")
            XCTAssertEqual(Set(models.map(\.id)).count, models.count)
            XCTAssertTrue(models.contains(where: \.isDefault), "\(harness.title) did not resolve its default")
        }
    }
}

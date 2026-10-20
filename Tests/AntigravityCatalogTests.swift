@testable import RotaCore
import XCTest

final class AntigravityCatalogTests: XCTestCase {
    func testMissingOtherHarnessExecutableDoesNotStartAProtocolPeer() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
        XCTAssertTrue(ModelCatalog.models(for: .codex, executable: missing).isEmpty)
    }

    func testNativeMetadataSeparatesFamiliesFromTheirEfforts() {
        let rows = AntigravityCatalog.rows("Loading...\nmodel-a-low\tModel A (Low)\nmodel-a-high\tModel A (High)\n")
        XCTAssertEqual(rows.count, 2)
        let options = AntigravityCatalog.family("model-a", rows: rows,
            model: ["id": "model-a-high", "label": "Model A (High)", "effort": "high"],
            effort: ["adjustable": true, "current": "high", "available": ["low", "high"]], current: "model-a-low")
        XCTAssertEqual(options?.id, "model-a")
        XCTAssertEqual(options?.title, "Model A")
        XCTAssertEqual(options?.efforts, ["low", "high"])
        XCTAssertEqual(options?.isDefault, true)
        XCTAssertTrue(options?.matches("model-a-low") == true)
        XCTAssertTrue(options?.matches("model-a-high") == true)
    }

    func testFixedEffortIsNotAnAdjustableTier() {
        let rows = AntigravityCatalog.rows("fixed-medium\tFixed Model (Medium)\n")
        let options = AntigravityCatalog.family("fixed", rows: rows,
            model: ["id": "fixed-medium", "label": "Fixed Model (Medium)", "effort": "medium"],
            effort: ["adjustable": false, "available": ["max"]], current: nil)
        XCTAssertEqual(options?.title, "Fixed Model")
        XCTAssertEqual(options?.efforts, [])
    }

    func testUnverifiedAliasesAndMissingMetadataNeverExposeGuessedFamilies() {
        let rows = AntigravityCatalog.rows("model-high\tModel High\n")
        for model in [nil, ["id": "different-model", "label": "Other", "effort": "high"]] {
            let options = AntigravityCatalog.family("model", rows: rows, model: model,
                effort: ["adjustable": true, "available": ["high"]], current: nil)
            XCTAssertNil(options)
        }
        let options = AntigravityCatalog.family("model", rows: rows,
            model: ["id": "model-high", "label": "Model High", "effort": "high"],
            effort: ["adjustable": true], current: nil)
        XCTAssertNil(options)
    }

    func testOnlyTheRequestedSuccessfulCommandProvidesMetadata() {
        let json = #"""
        {"status":"SUCCESS","command":{"name":"effort","data":{"adjustable":false}}}
        """#
        XCTAssertEqual(AntigravityCatalog.payload(json, command: "effort")?["adjustable"] as? Bool, false)
        XCTAssertNil(AntigravityCatalog.payload(json, command: "model"))
        XCTAssertNil(AntigravityCatalog.payload(
            json.replacingOccurrences(of: "SUCCESS", with: "ERROR"), command: "effort"))
        XCTAssertNil(AntigravityCatalog.payload("not json", command: "effort"))
    }

    /// Exercises the real CLI invocation seam, including native alias validation.
    func testCatalogReadsNativeFamilyAndEffortMetadataWithoutStartingTurns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("agy")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/antigravity-catalog.sh")
        let script = try String(contentsOf: fixture, encoding: .utf8)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let options = ModelCatalog.models(for: .antigravity, executable: executable.path)
        XCTAssertEqual(options.map(\.id), ["model-a", "fixed"])
        XCTAssertEqual(options.map(\.title), ["Model A", "Fixed"])
        XCTAssertEqual(options.map(\.efforts), [["low", "high"], []])
        XCTAssertEqual(options.map(\.isDefault), [true, false])
        // A lost native reply must not turn one family back into effort-specific rows.
        let broken = script.replacingOccurrences(of: "elif [[ \"$model\" == fixed ]]; then",
                                                with: "elif [[ \"$model\" == fixed ]]; then exit 7")
        XCTAssertNotEqual(script, broken)
        try broken.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertTrue(ModelCatalog.models(for: .antigravity, executable: executable.path).isEmpty)
    }
}

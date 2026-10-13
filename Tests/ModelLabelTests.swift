@testable import Rota
@testable import RotaCore
import XCTest

final class ModelLabelTests: XCTestCase {
    private var routine: Routine {
        Routine(id: "model-label", name: "Model label", workingDirectory: "/tmp/model-label",
                schedule: "0 9 * * *", harness: .claude, prompt: "Fixture", model: "haiku")
    }

    private var record: RunRecord {
        RunRecord(routineID: routine.id, trigger: .manual, harness: .claude,
                  startedAt: Date(timeIntervalSince1970: 0), outcome: .succeeded)
    }

    func testReportedClaudeIDsUseReadableNamesAndKeepTheFullID() {
        for (id, title) in [("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5", "Sonnet 5"),
                            ("claude-sonnet-4-5-20250929", "Sonnet 4.5")] {
            var record = record
            record.metadata = SessionMetadata(model: id)
            XCTAssertEqual(ModelLabel.name(harness: .claude, routine: routine, models: [:], record: record),
                           "Claude Code \u{00B7} " + title)
            XCTAssertEqual(ModelLabel.modelID(harness: .claude, routine: routine, record: record), id)
        }
    }

    func testActualModelWinsAndMissingActualUsesTheLaunchSnapshot() {
        var record = record
        record.configuration = RunConfiguration(model: "opus", effort: nil, workingDirectory: "/tmp/model-label")
        record.metadata = SessionMetadata(model: "claude-sonnet-5")
        XCTAssertEqual(ModelLabel.modelID(harness: .claude, routine: routine, record: record), "claude-sonnet-5")
        record.metadata = SessionMetadata(model: " ")
        let models = [ModelOption(id: "opus", title: "Opus 5.5", efforts: [])]
        XCTAssertEqual(ModelLabel.name(harness: .claude, routine: routine, models: [.claude: models], record: record),
                       "Claude Code \u{00B7} Opus 5.5")
    }

    func testDefaultLaunchDoesNotBorrowTheRoutinesCurrentModel() {
        var record = record
        record.configuration = RunConfiguration(model: nil, effort: nil, workingDirectory: "/tmp/model-label")
        XCTAssertNil(ModelLabel.modelID(harness: .claude, routine: routine, record: record))
        XCTAssertEqual(ModelLabel.name(harness: .claude, routine: routine, models: [:], record: record), "Claude Code")
        XCTAssertNil(ModelLabel.modelID(harness: .codex, routine: routine))
    }

    func testProviderCatalogTitleWinsAndUnknownIDsRemainIntact() {
        var record = record
        record.metadata = SessionMetadata(model: "provider-model")
        let models = [Harness.codex: [ModelOption(id: "provider-model", title: "Provider Model", efforts: [])]]
        XCTAssertEqual(ModelLabel.name(harness: .codex, routine: routine, models: models, record: record),
                       "Codex \u{00B7} Provider Model")
        for id in ["provider-model", "claude-preview-experimental", "claude-opus-5-5-extra"] {
            record.metadata = SessionMetadata(model: id)
            XCTAssertEqual(ModelLabel.name(harness: .claude, routine: routine, models: [:], record: record),
                           "Claude Code \u{00B7} " + id)
        }
    }
}

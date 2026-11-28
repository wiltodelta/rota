import Observation
import RotaCore
@testable import Rota
import XCTest

@MainActor
final class AppSettingsTests: XCTestCase {
    func testReadyCatalogIsPublishedWhileAnotherAgentIsStillReading() async throws {
        let suite = "rota-settings-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, refreshOnInit: false)
        let peer = CatalogGate()
        let published = expectation(description: "ready catalog published")
        withObservationTracking {
            _ = settings.models
        } onChange: {
            Task { @MainActor in published.fulfill() }
        }
        let option = ModelOption(id: "model-a", title: "Model A", efforts: ["low", "high"])
        let refresh = settings.refreshInstalled(discover: { [:] }, catalog: { harness, _ in
            if harness != .antigravity { await peer.wait() }
            return harness == .antigravity ? [option] : []
        })
        await fulfillment(of: [published], timeout: 10)
        XCTAssertEqual(settings.models[.antigravity], [option])
        XCTAssertNil(settings.models[.claude], "The slow CLI has not been released")
        await peer.release()
        await refresh.value
        XCTAssertTrue(settings.loadingModels.isEmpty)
    }

    func testCancelledRefreshCannotReplaceNewerCatalogs() async throws {
        let suite = "rota-settings-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, refreshOnInit: false)
        let peer = CatalogGate()
        let old = ModelOption(id: "old", title: "Old", efforts: [])
        let current = ModelOption(id: "current", title: "Current", efforts: ["high"])
        let entered = expectation(description: "old catalog blocked")
        let previous = settings.refreshInstalled(discover: { [:] }, catalog: { harness, _ in
            if harness == .antigravity { entered.fulfill() }
            await peer.wait()
            return [old]
        })
        await fulfillment(of: [entered], timeout: 10)
        let latest = settings.refreshInstalled(discover: { [:] }, catalog: { _, _ in [current] })
        await latest.value
        XCTAssertEqual(settings.models[.antigravity], [current])
        await peer.release()
        await previous.value
        XCTAssertTrue(settings.models.values.allSatisfy { $0 == [current] })
        XCTAssertTrue(settings.loadingModels.isEmpty)
    }

    func testDiscussionChoicesPersistPerAgentAndFallBackWhenTheCatalogDropsThem() async throws {
        let suite = "rota-settings-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, refreshOnInit: false)
        settings.discussionModels[.codex] = "model-b"
        settings.discussionEfforts[.codex] = "high"
        // Before the catalog loads, the stored choice stands.
        let unloaded = settings.discussionSetup(for: .codex)
        XCTAssertFalse(unloaded.effortFixed, "Before the catalog loads, the effort picker still opens")
        XCTAssertEqual(unloaded.model, "model-b")
        XCTAssertEqual(unloaded.effort, "high")
        let reloaded = AppSettings(defaults: defaults, refreshOnInit: false)
        XCTAssertEqual(reloaded.discussionModels, [.codex: "model-b"])
        XCTAssertEqual(reloaded.discussionEfforts, [.codex: "high"])
        let fallback = ModelOption(id: "model-a", title: "Model A", efforts: ["low"], isDefault: true)
        let chosen = ModelOption(id: "model-b", title: "Model B", efforts: ["low", "high"])
        await settings.refreshInstalled(discover: { [:] }, catalog: { _, _ in [fallback, chosen] }).value
        let offered = settings.discussionSetup(for: .codex)
        XCTAssertEqual(offered.model, "model-b")
        XCTAssertEqual(offered.effort, "high")
        XCTAssertEqual(offered.modelTitle, "Model B")
        // A model the agent no longer lists, and an effort its default lacks, fall back to defaults.
        await settings.refreshInstalled(discover: { [:] }, catalog: { _, _ in [fallback] }).value
        let dropped = settings.discussionSetup(for: .codex)
        XCTAssertNil(dropped.model)
        XCTAssertNil(dropped.effort)
        XCTAssertEqual(dropped.selected, fallback)
        XCTAssertEqual(dropped.modelTitle, "Model A")
        XCTAssertFalse(dropped.effortFixed)
        let fixed = ModelOption(id: "fixed", title: "Fixed", efforts: [], isDefault: true)
        await settings.refreshInstalled(discover: { [:] }, catalog: { _, _ in [fixed] }).value
        XCTAssertTrue(settings.discussionSetup(for: .codex).effortFixed,
                      "A listed model without efforts has none to pick")
    }
}

private actor CatalogGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

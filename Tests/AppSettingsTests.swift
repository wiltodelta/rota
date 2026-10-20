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

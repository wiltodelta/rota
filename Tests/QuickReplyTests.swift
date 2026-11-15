@testable import Rota
import XCTest

@MainActor
final class QuickReplyTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "rota-replies-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testNewInstallShipsCommitCommitAndPushAndContinue() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, refreshOnInit: false)
            XCTAssertEqual(settings.sendableReplies.map(\.text), ["Commit", "Commit and push", "Continue"])
            XCTAssertTrue(settings.missingDefaultReplies.isEmpty)
        }
    }

    func testDeletedDefaultStaysDeletedAndRestoreAddsOnlyIt() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, refreshOnInit: false)
            settings.quickReplies.removeAll { $0.title == "Commit" }
            settings.quickReplies.append(QuickReply(title: "Tests", message: "Run the tests"))
            let reopened = AppSettings(defaults: defaults, refreshOnInit: false)
            XCTAssertEqual(reopened.quickReplies.map(\.label), ["Commit and Push", "Continue", "Tests"])
            XCTAssertEqual(reopened.missingDefaultReplies.map(\.label), ["Commit"])
            reopened.restoreDefaultReplies()
            XCTAssertEqual(reopened.quickReplies.map(\.label), ["Commit", "Commit and Push", "Continue", "Tests"])
            XCTAssertTrue(reopened.missingDefaultReplies.isEmpty)
        }
    }

    func testRemovingEveryReplyIsKept() throws {
        try withDefaults { defaults in
            AppSettings(defaults: defaults, refreshOnInit: false).quickReplies = []
            XCTAssertTrue(AppSettings(defaults: defaults, refreshOnInit: false).quickReplies.isEmpty)
        }
    }

    func testReplyWithoutMessageIsHiddenAndUntitledOneUsesItsFirstLine() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, refreshOnInit: false)
            settings.quickReplies = [QuickReply(title: "Empty", message: "  \n"),
                                     QuickReply(title: " ", message: " Review the diff\nthen fix it ")]
            XCTAssertEqual(settings.sendableReplies.map(\.label), ["Review the diff"])
            XCTAssertEqual(settings.sendableReplies.first?.text, "Review the diff\nthen fix it")
        }
    }
}

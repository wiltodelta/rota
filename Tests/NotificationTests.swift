@testable import Rota
@testable import RotaCore
import XCTest

@MainActor
final class NotificationTests: XCTestCase {
    func testStructuredQuestionOpensTheFormInsteadOfOfferingAnUnstructuredReply() {
        let notifier = Notifier()
        notifier.canReply = { _ in true }
        var record = RunRecord(routineID: "sample", trigger: .manual, harness: .codex,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .running)
        record.questions = [.init(title: "Choose a color")]
        let content = notifier.sessionContent(record, routine: nil, title: nil,
                                              text: "Choose a color", needsReply: true)
        XCTAssertTrue(content.categoryIdentifier.isEmpty)
        XCTAssertEqual(content.subtitle, "Needs your reply")
        XCTAssertTrue(content.userInfo.values.contains { $0 as? String == record.id.uuidString })
    }

    func testReplyActionMatchesTheSchedulersCapabilities() {
        let location = StorageLocation(root: URL(fileURLWithPath: "/unused"),
                                       logs: URL(fileURLWithPath: "/unused/logs"))
        let scheduler = Scheduler(location: location, launcher: UnusedLauncher())
        let notifier = Notifier()
        notifier.canReply = { scheduler.canMessage($0) }
        for harness in Harness.allCases {
            var record = RunRecord(routineID: "sample", trigger: .manual, harness: harness,
                                   startedAt: Date(timeIntervalSince1970: 0), outcome: .succeeded)
            record.sessionID = "synthetic-session"
            let content = notifier.sessionContent(record, routine: nil, title: nil, text: "Review it",
                                                   needsReply: true)
            XCTAssertEqual(content.body, "Review it")
            if harness == .shell {
                XCTAssertTrue(content.categoryIdentifier.isEmpty)
                XCTAssertEqual(content.subtitle, "Needs your attention")
            } else {
                XCTAssertFalse(content.categoryIdentifier.isEmpty)
                XCTAssertEqual(content.subtitle, "Needs your reply")
            }
            record.sessionID = nil
            let unavailable = notifier.sessionContent(record, routine: nil, title: nil, text: "Review it",
                                                       needsReply: true)
            XCTAssertTrue(unavailable.categoryIdentifier.isEmpty)
            XCTAssertEqual(unavailable.subtitle, "Needs your attention")
        }
    }
}

private final class UnusedLauncher: RoutineLaunching {
    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        fatalError("Notification content tests must never launch a routine")
    }
}

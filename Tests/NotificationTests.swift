@testable import Rota
@testable import RotaCore
import XCTest
import UserNotifications

@MainActor
final class NotificationTests: XCTestCase {
    func testOnlyInformationalNotificationsExpireAfterDelivery() {
        let notifier = Notifier()
        notifier.notifyOnSuccess = { true }
        var delivered: [String] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var expirations: [@MainActor @Sendable () -> Void] = []
        var removed: [String] = []
        notifier.deliver = { request, completion in
            delivered.append(request.identifier)
            completions.append(completion)
        }
        notifier.scheduleExpiry = { delay, action in
            XCTAssertEqual(delay, 8)
            expirations.append(action)
        }
        notifier.removeDelivered = { removed += $0 }
        let routine = Routine(id: "sample", name: "Sample", workingDirectory: "/unused",
                              schedule: "0 9 * * *", prompt: "Sample")
        var record = RunRecord(routineID: routine.id, trigger: .manual, harness: .codex,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .succeeded)
        notifier.runEnded(record, routine: routine)
        notifier.routineAdded(routine)
        notifier.sessionNotified(record, routine: routine, title: nil, text: "Done", needsReply: false)
        let temporaryIDs = delivered
        XCTAssertEqual(temporaryIDs.count, 3)
        XCTAssertTrue(expirations.isEmpty, "Expiry must start after delivery, not submission")
        for completion in completions { completion(nil) }
        XCTAssertEqual(expirations.count, 3)
        for expire in expirations { expire() }
        XCTAssertEqual(removed, temporaryIDs)

        expirations.removeAll()
        completions.removeAll()
        notifier.sessionNotified(record, routine: routine, title: nil, text: "Choose", needsReply: true)
        record.attention = "Review"
        notifier.sessionNotified(record, routine: routine, title: nil, text: "Review", needsReply: false)
        notifier.runEnded(record, routine: routine)
        record.attention = nil
        record.questions = [.init(title: "Choose")]
        notifier.sessionNotified(record, routine: routine, title: nil, text: "Choose", needsReply: false)
        record.questions = nil
        for outcome in [RunOutcome.failed(exitCode: 1), .timedOut, .interrupted,
                        .launchFailed("Unavailable"), .skipped("Missed slot")] {
            record.outcome = outcome
            notifier.runEnded(record, routine: routine)
            notifier.sessionNotified(record, routine: routine, title: nil, text: "Problem", needsReply: false)
        }
        notifier.routinePaused(routine, failures: 5)
        XCTAssertEqual(completions.count, 15)
        for completion in completions { completion(nil) }
        XCTAssertTrue(expirations.isEmpty, "Questions and problems must never expire")
        XCTAssertEqual(removed, temporaryIDs)
    }

    func testFailedDeliveryDoesNotScheduleRemoval() {
        let notifier = Notifier()
        var attempted = false
        notifier.deliver = { _, completion in
            attempted = true
            completion(NSError(domain: "NotificationTests", code: 1))
        }
        notifier.scheduleExpiry = { _, _ in XCTFail("An undelivered notification must not expire") }
        notifier.removeDelivered = { _ in XCTFail("No notification was delivered") }
        notifier.sessionNotified(nil, routine: nil, title: nil, text: "Information", needsReply: false)
        XCTAssertTrue(attempted)
    }

    func testOldSuccessExpiryCannotRemoveALaterFailureForTheSameRun() throws {
        let notifier = Notifier()
        notifier.notifyOnSuccess = { true }
        var delivered: [String] = []
        var expire: (@MainActor @Sendable () -> Void)?
        var removed: [String] = []
        notifier.deliver = { request, completion in
            delivered.append(request.identifier)
            completion(nil)
        }
        notifier.scheduleExpiry = { _, action in expire = action }
        notifier.removeDelivered = { removed += $0 }
        let routine = Routine(id: "sample", name: "Sample", workingDirectory: "/unused",
                              schedule: "0 9 * * *", prompt: "Sample")
        var record = RunRecord(routineID: routine.id, trigger: .manual, harness: .codex,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .succeeded)
        notifier.runEnded(record, routine: routine)
        record.outcome = .failed(exitCode: 1)
        notifier.runEnded(record, routine: routine)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertNotEqual(delivered[0], delivered[1])
        try XCTUnwrap(expire)()
        XCTAssertEqual(removed, [delivered[0]])
        XCTAssertFalse(removed.contains(delivered[1]))
    }

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

import Foundation
@testable import RotaCore
import XCTest

final class ClaudeDialogRecoveryTests: XCTestCase {
    func testUnreadableDialogIsRetriedWithoutAnotherNotification() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let recovered = expectation(description: "unreadable and recovered questions")
        recovered.expectedFulfillmentCount = 2
        let resolved = expectation(description: "unreadable question replaced")
        let journal = RunJournal(output: try FileHandle(forWritingTo: log), events: RunEvents(
            session: { _ in }, finished: { _ in }, question: { question, _ in
                if question.actions.isEmpty { XCTAssertTrue(question.detail.contains("cannot read")) } else {
                    XCTAssertEqual(question.actions.map(\.label), ["Allow once", "No"])
                }
                recovered.fulfill()
            }, questionResolved: { _ in resolved.fulfill() }))
        var screen: ClaudeDialog?
        let bridge = ClaudeDialogBridge(screen: "synthetic", session: "synthetic", folder: folder,
            journal: journal, queue: .main, readScreen: { screen }, typeKey: { _ in
                XCTFail("Recovering choices must never send input")
            })
        try (Data(#"{"hook_event_name":"Notification","message":"Claude needs your permission"}"#.utf8)
            + Data([10])).write(to: bridge.file)
        bridge.poll()
        screen = ClaudeDialog(prompt: ["Allow access?"], options: ["Allow once", "No"])
        bridge.poll()
        bridge.poll()
        wait(for: [recovered, resolved], timeout: 1)
        journal.finish(.succeeded)
    }
}

import Foundation
@testable import RotaCore
import XCTest

final class ClaudeDialogRecoveryTests: XCTestCase {
    private func notify(_ bridge: ClaudeDialogBridge) throws {
        let line = Data(#"{"hook_event_name":"Notification","message":"Claude needs your permission"}"#.utf8)
            + Data([10])
        if FileManager.default.fileExists(atPath: bridge.file.path) {
            let handle = try FileHandle(forWritingTo: bridge.file)
            try handle.seekToEnd()
            handle.write(line)
            try handle.close()
        } else {
            try line.write(to: bridge.file)
        }
        bridge.poll()
    }

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
        try notify(bridge)
        screen = ClaudeDialog(prompt: ["Allow access?"], options: ["Allow once", "No"])
        bridge.poll()
        bridge.poll()
        wait(for: [recovered, resolved], timeout: 1)
        journal.finish(.succeeded)
    }

    func testBridgeAnswersUnnumberedDialogFromLiveSelectionWithoutExtraReturn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let options = ["Deny, and tell Claude what to do differently (esc)", "Allow for this session (1 app)"]
        var screen: ClaudeDialog? = ClaudeDialog(prompt: ["Computer Use wants to control these apps"],
                                                 options: options, selected: 0, numbered: false)
        var typed: [String] = []
        var closeOnType = false
        var reply: ((QuestionAnswer) -> Void)?
        var asked = expectation(description: "unnumbered dialog shown")
        let journal = RunJournal(output: try FileHandle(forWritingTo: log), events: RunEvents(
            session: { _ in }, finished: { _ in }, question: { _, callback in
                reply = callback
                asked.fulfill()
            }))
        let bridge = ClaudeDialogBridge(screen: "synthetic", session: "synthetic", folder: folder,
            journal: journal, queue: .main, readScreen: { screen }, typeKey: { key in
                typed.append(key)
                if closeOnType { screen = nil }
            })
        try notify(bridge)
        wait(for: [asked], timeout: 1)

        reply?(QuestionAnswer(action: options[1]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.85))
        XCTAssertEqual(typed, ["\u{1B}[B\r"],
                       "confirm must not send a second Return when an unnumbered dialog stays open")

        // Open again, move focus in Terminal before answering, and verify delta comes from live selection.
        typed.removeAll()
        closeOnType = true
        asked = expectation(description: "second unnumbered dialog shown")
        try notify(bridge)
        wait(for: [asked], timeout: 1)
        screen?.selected = 1
        reply?(QuestionAnswer(action: options[1]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(typed, ["\r"])
        journal.finish(.succeeded)
    }
}

@testable import Rota
@testable import RotaCore
import SwiftUI
import XCTest

/// Contracts from the 2026-10-21 UX audit.
final class UXAuditTests: XCTestCase {
    func testAFinishedSessionWithAPendingQuestionNeedsAReply() {
        var record = RunRecord(routineID: "a", trigger: .manual, harness: .codex,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .succeeded)
        XCTAssertEqual(record.statusTitle, "Completed")
        record.questions = [AgentQuestion(id: "q", title: "Which color?")]
        XCTAssertEqual(record.statusTitle, "Needs your reply")
        record.outcome = .failed(exitCode: 1)
        XCTAssertEqual(record.statusTitle, "Failed (exit 1)", "A failure still reads as a failure")
    }

    func testTheNewRoutineSheetNamesTheIdTheWayItsFieldIsLabeled() {
        var draft = Routine(id: "", name: "", workingDirectory: "/", schedule: "0 9 * * 1-5", enabled: true,
                            prompt: "run")
        draft.harness = .claude
        XCTAssertEqual(NewRoutineSheet.problem(draft),
                       "Enter the project skill this routine runs, such as weekly-report.")
        draft.id = "Weekly Report"
        XCTAssertEqual(NewRoutineSheet.problem(draft), "A skill name is lowercase letters, digits, - and _.")
        draft.harness = .shell
        XCTAssertEqual(NewRoutineSheet.problem(draft), "An ID is lowercase letters, digits, - and _.")
        draft.id = ""
        XCTAssertEqual(NewRoutineSheet.problem(draft), "Give the routine an ID, such as weekly-backup.")
        draft.id = "weekly-backup"
        XCTAssertNil(NewRoutineSheet.problem(draft))
        XCTAssertEqual(draft.problem(), NewRoutineSheet.problem(draft), "Past the id, the shared check decides")
    }

    func testSidebarCaptionsStaySecondaryOutsideTheActiveSelection() {
        XCTAssertEqual(SidebarText.caption(onAccent: false), Color.secondaryText)
        XCTAssertEqual(SidebarText.caption(onAccent: true), Color.primary)
    }
}

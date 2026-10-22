@testable import Rota
@testable import RotaCore
import AppKit
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
        XCTAssertEqual(SidebarText.caption(onAccent: true), SidebarText.primary(onAccent: true))
    }

    func testSelectedSidebarTextContrastsWithLightAndDarkAccents() {
        // These are the actual selection fills captured on macOS 27, plus the
        // light and dark extremes a user's accent can take.
        for fill in [NSColor(srgbRed: 0, green: 122 / 255, blue: 1, alpha: 1),
                     NSColor(srgbRed: 0, green: 112 / 255, blue: 245 / 255, alpha: 1),
                     .white, .black] {
            let foreground = SidebarText.foreground(on: fill)
            let dark = min(luminance(foreground), luminance(fill))
            let light = max(luminance(foreground), luminance(fill))
            XCTAssertGreaterThanOrEqual((light + 0.05) / (dark + 0.05), 4.5)
        }
    }

    private func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear(rgb.redComponent) * 0.2126 + linear(rgb.greenComponent) * 0.7152
            + linear(rgb.blueComponent) * 0.0722
    }
}

@testable import Rota
@testable import RotaCore
import AppKit
import SwiftUI
import XCTest

@MainActor
final class SessionRequestViewTests: XCTestCase {
    func testRenderPermissionAndQuestionsAtTheMinimumChatWidth() throws {
        guard let destination = ProcessInfo.processInfo.environment["ROTA_REQUEST_RENDER_DIR"] else {
            throw XCTSkip("set ROTA_REQUEST_RENDER_DIR to render native request fixtures")
        }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let permission = RequestPresentation.permission(title: "Allow command?", detail:
            "command: echo sample-report\n\ncwd: /tmp/sample\n\nreason: Check the report before continuing.")
        let questions = try XCTUnwrap(RequestPresentation.codex("item/tool/requestUserInput", ["questions": [
            ["id": "destination", "question": "Where should the report be saved?", "isOther": true,
             "options": [["label": "Local folder", "description": "Save it beside the report"]]],
            ["id": "note", "question": "Add a note for the report."]]]))
        let multiple = try XCTUnwrap(RequestPresentation.claude(["tool_name": "AskUserQuestion", "input": [
            "questions": [["question": "Which sections should the report include?", "multiSelect": true,
                "options": [["label": "Summary", "description": "Show the totals"],
                            ["label": "Details", "description": "Show every entry"]]]]]]))
        var fixtures = [("permission", permission), ("questions", questions), ("multiple", multiple)]
        if let manifest = ProcessInfo.processInfo.environment["ROTA_HOOK_LIVE_MANIFEST"] {
            let captured = URL(fileURLWithPath: manifest).deletingLastPathComponent()
            for name in ["permission", "question"] {
                let file = captured.appendingPathComponent(name + "-request.json")
                let request = try JSONDecoder().decode(SessionRequest.self, from: Data(contentsOf: file))
                fixtures.append(("interactive-" + name, request))
            }
        }
        for (name, request) in fixtures {
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try render(request, name: name + "-" + theme, appearance: appearance, folder: folder)
            }
        }
    }

    private func render(_ request: SessionRequest, name: String, appearance: NSAppearance.Name, folder: URL) throws {
        let hosting = NSHostingView(rootView: SessionRequestView(request: request) { _ in })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let destination = folder.appendingPathComponent(name + ".png")
        let capture = ProcessLauncher.capture("/usr/sbin/screencapture",
            ["-x", "-o", "-l", String(window.windowNumber), destination.path],
            in: folder.path, loginShell: false)
        XCTAssertEqual(capture.0, 0, capture.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(hosting.bounds.width, 520)
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, hosting.bounds.height)
        window.close()
    }

}

@testable import Rota
@testable import RotaCore
import AppKit
import SwiftUI
import XCTest

@MainActor
final class ChatAttachmentViewTests: XCTestCase {
    func testNativeAttachmentPreviewsInBothAppearances() throws {
        guard let destination = ProcessInfo.processInfo.environment["ROTA_ATTACHMENT_RENDER_DIR"] else {
            throw XCTSkip("set ROTA_ATTACHMENT_RENDER_DIR to render attachment fixtures")
        }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: destination)
        let fixture = try AttachmentTestFixture.create(in: folder.appendingPathComponent("fixture"))
        let files = try fixture.files.map(ChatAttachment.inspect)
        var item = TranscriptItem(id: 0, kind: .user, text: "Attached image and report")
        item.attachments = files
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let style = TranscriptStyle(family: "", codeFamily: "", size: 14)
            let text = TranscriptDocument(style: style).make(items: [item], running: false,
                                                            activity: [:])
            let transcript = TranscriptScrollView()
            transcript.frame = NSRect(x: 0, y: 90, width: 520, height: 380)
            transcript.update(text)
            let strip = NSHostingView(rootView: ChatAttachmentStrip(files: files) { _ in }
                .padding(12)
                .background(Color.primary.opacity(0.045)))
            strip.frame = NSRect(x: 0, y: 0, width: 520, height: 90)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 470))
            root.addSubview(transcript)
            root.addSubview(strip)
            let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = .textBackgroundColor
            window.contentView = root
            window.makeKeyAndOrderFront(nil)
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertLessThanOrEqual(strip.fittingSize.height, strip.bounds.height)
            let path = folder.appendingPathComponent("attachments-" + theme + ".png")
            let result = ProcessLauncher.capture("/usr/sbin/screencapture",
                ["-x", "-o", "-l", String(window.windowNumber), path.path], in: folder.path, loginShell: false)
            XCTAssertEqual(result.0, 0, result.1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
            window.close()
        }
    }
}

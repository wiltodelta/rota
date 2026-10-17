import AppKit
@testable import Rota
import XCTest

@MainActor
final class TranscriptViewportTests: XCTestCase {
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var document: FlippedDocument!
    private var marker: NSView!
    private var viewport: TranscriptViewport!

    override func setUp() async throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                          styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView = scroll
        document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
        scroll.documentView = document
        viewport = TranscriptViewport()
        let partial = NSView(frame: NSRect(x: 0, y: 200, width: 300, height: 200))
        document.addSubview(partial)
        viewport.register(partial, id: 1)
        marker = NSView(frame: NSRect(x: 0, y: 450, width: 300, height: 50))
        document.addSubview(marker)
        viewport.register(marker, id: 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    func testCapturesFirstFullyVisibleMessageAndRestoresItsPixelOffset() async throws {
        viewport.remember()
        let anchor = try XCTUnwrap(viewport.anchorForUpdate())
        XCTAssertEqual(anchor.id, 2)
        XCTAssertEqual(anchor.offset, 150, accuracy: 0.5)
        marker.frame.origin.y += 318
        XCTAssertEqual(marker.frame.minY, 768, "The layout mutation must actually move the message")
        XCTAssertEqual(scroll.documentVisibleRect.minY, 300, accuracy: 0.5)
        let retained = try XCTUnwrap(viewport.anchorForUpdate())
        XCTAssertEqual(retained.id, anchor.id)
        XCTAssertEqual(retained.offset, anchor.offset, accuracy: 0.5,
                       "Layout must use the saved reading position, not capture the already moved row")
        viewport.restoreAfterLayout(retained)
        viewport.remember()
        XCTAssertEqual(try XCTUnwrap(viewport.anchorForUpdate()).offset, anchor.offset, accuracy: 0.5)
        await flushMainQueue()
        let restored = try XCTUnwrap(viewport.capture())
        XCTAssertEqual(restored.id, 2)
        XCTAssertEqual(restored.offset, anchor.offset, accuracy: 0.5)
        XCTAssertEqual(scroll.documentVisibleRect.minY, 618, accuracy: 0.5)
    }

    func testUserScrollCancelsQueuedCorrection() async throws {
        let anchor = try XCTUnwrap(viewport.capture())
        marker.frame.origin.y += 318
        viewport.restoreAfterLayout(anchor)
        viewport.cancel()
        await flushMainQueue()
        XCTAssertEqual(scroll.documentVisibleRect.minY, 300, accuracy: 0.5)
    }

    func testDismantledMarkerIsNotUsedAsAnAnchor() throws {
        viewport.remove(marker, id: 2)
        XCTAssertEqual(try XCTUnwrap(viewport.capture()).id, 1)
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

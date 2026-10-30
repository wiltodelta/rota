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

    func testDisclosureCanAnchorItsOwnPartiallyVisibleHeader() throws {
        let anchor = try XCTUnwrap(viewport.capture(id: 1))
        XCTAssertEqual(anchor.id, 1)
        XCTAssertEqual(anchor.offset, -100, accuracy: 0.5)
        XCTAssertNil(viewport.capture(id: 99))
    }

    func testUserScrollCancelsQueuedCorrection() async throws {
        let anchor = try XCTUnwrap(viewport.capture())
        marker.frame.origin.y += 318
        viewport.restoreAfterLayout(anchor)
        viewport.cancel()
        await flushMainQueue()
        XCTAssertEqual(scroll.documentVisibleRect.minY, 300, accuracy: 0.5)
    }

    func testHiddenCachedMarkerCannotBecomeTheReadingAnchor() throws {
        let cached = NSView(frame: NSRect(x: 0, y: 310, width: 300, height: 50))
        document.addSubview(cached)
        cached.isHidden = true
        viewport.register(cached, id: 3)
        XCTAssertEqual(try XCTUnwrap(viewport.capture()).id, 2)
    }

    func testDismantledMarkerIsNotUsedAsAnAnchor() throws {
        viewport.remove(marker, id: 2)
        XCTAssertEqual(try XCTUnwrap(viewport.capture()).id, 1)
    }

    func testEndRequestFollowsActualDocumentHeightUntilUserScrolls() async {
        let end = TranscriptMarker.MarkerView(frame: NSRect(x: 0, y: 1999, width: 300, height: 1))
        end.id = Int.min
        end.viewport = viewport
        document.addSubview(end)
        viewport.register(end, id: Int.min)
        viewport.followEnd()
        await flushMainQueue()
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 0.5)

        // Lazy rows replace estimates as they materialize; the request must survive that layout.
        document.setFrameSize(NSSize(width: 300, height: 2800))
        end.setFrameOrigin(NSPoint(x: 0, y: 2799))
        await flushMainQueue()
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 0.5)

        // A native anchor adjustment can arrive after the document has finished resizing.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        await flushMainQueue()
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 0.5)

        viewport.cancel()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        document.setFrameSize(NSSize(width: 300, height: 3000))
        end.setFrameOrigin(NSPoint(x: 0, y: 2999))
        viewport.layoutChanged()
        await flushMainQueue()
        XCTAssertEqual(scroll.documentVisibleRect.minY, 700, accuracy: 0.5)
    }

    func testUserScrollCancelsQueuedEndRequest() async {
        viewport.register(marker, id: Int.min)
        viewport.followEnd()
        viewport.cancel()
        await flushMainQueue()
        XCTAssertEqual(scroll.documentVisibleRect.minY, 300, accuracy: 0.5)
    }

    func testProgrammaticScrollCannotResumeFollowing() {
        var state = TranscriptScrollState()
        state.following = false
        _ = state.changePhase(.animating, atEnd: true)
        state.moved(atEnd: true)
        _ = state.changePhase(.idle, atEnd: true)
        XCTAssertFalse(state.following, "Layout and anchor corrections are not a user request to follow")
    }

    func testManualScrollResumesFollowingOnlyWhenItReachesTheEnd() {
        var state = TranscriptScrollState()
        XCTAssertTrue(state.changePhase(.interacting, atEnd: true))
        XCTAssertFalse(state.following, "Input must release the end before the first offset update")
        state.moved(atEnd: false)
        _ = state.changePhase(.idle, atEnd: false)
        XCTAssertFalse(state.following)
        _ = state.changePhase(.interacting, atEnd: false)
        state.moved(atEnd: true)
        _ = state.changePhase(.idle, atEnd: true)
        XCTAssertTrue(state.following)
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

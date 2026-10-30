import AppKit
import SwiftUI

/// SwiftUI's lazy estimates can move a message even while its ID stays selected.
/// These invisible markers restore the actual pixel offset after a transcript update.
@MainActor
final class TranscriptViewport: NSObject {
    struct Anchor {
        let id: Int
        let offset: CGFloat
        let point: UnitPoint
    }

    private struct WeakMarker { weak var view: NSView? }
    private var markers: [Int: WeakMarker] = [:]
    private var revision = 0
    private var readingAnchor: Anchor?
    private var restoring = false

    private(set) var isFollowingEnd = false
    private var endUpdateQueued = false
    private weak var followedScroll: NSScrollView?
    private weak var followedDocument: NSView?

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Keep an explicit jump at the real end while lazy rows replace their height estimates.
    func followEnd() {
        cancel()
        isFollowingEnd = true
        layoutChanged()
    }

    func layoutChanged() {
        guard isFollowingEnd, !endUpdateQueued else { return }
        endUpdateQueued = true
        let request = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == request else { return }
            self.endUpdateQueued = false
            guard let view = self.markers[Int.min]?.view,
                  let scroll = view.enclosingScrollView, let document = scroll.documentView else { return }
            self.observeEnd(in: scroll, document: document)
            scroll.layoutSubtreeIfNeeded()
            let visible = scroll.documentVisibleRect
            let end = max(document.bounds.minY, document.bounds.maxY - visible.height)
            guard abs(visible.minY - end) > 0.25 else { return }
            scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: end))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Native layout can settle after SwiftUI has already delivered its geometry callback.
    private func observeEnd(in scroll: NSScrollView, document: NSView) {
        guard followedScroll !== scroll || followedDocument !== document else { return }
        stopObservingEnd()
        followedScroll = scroll
        followedDocument = document
        scroll.contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(endGeometryChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(endGeometryChanged),
                                               name: NSView.frameDidChangeNotification, object: document)
    }

    @objc private func endGeometryChanged() { layoutChanged() }

    func register(_ view: NSView, id: Int) {
        markers[id] = WeakMarker(view: view)
        if id == Int.min { layoutChanged() }
    }

    func remove(_ view: NSView, id: Int) {
        if markers[id]?.view === view { markers[id] = nil }
    }

    private struct Candidate {
        let id: Int
        let frame: CGRect
        let visible: CGRect
    }

    func capture(id requestedID: Int? = nil) -> Anchor? {
        let candidates = markers.compactMap { id, marker -> Candidate? in
            guard id != Int.min, requestedID == nil || requestedID == id,
                  let view = marker.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
                  let scroll = view.enclosingScrollView, let document = scroll.documentView else { return nil }
            return Candidate(id: id, frame: view.convert(view.bounds, to: document),
                             visible: scroll.documentVisibleRect)
        }
        let visible = candidates.filter { $0.frame.intersects($0.visible) }
        let complete = visible.filter { $0.frame.minY >= $0.visible.minY - 0.5 }
        guard let first = (complete.isEmpty ? visible : complete).min(by: { $0.frame.minY < $1.frame.minY }) else {
            return nil
        }
        let offset = first.frame.minY - first.visible.minY
        let distance = first.visible.height - first.frame.height
        let point = abs(distance) > 1 ? UnitPoint(x: 0, y: offset / distance) : .top
        return Anchor(id: first.id, offset: offset, point: point)
    }

    func remember() {
        if !restoring { readingAnchor = capture() }
    }

    func anchorForUpdate() -> Anchor? { readingAnchor ?? capture() }

    private func stopObservingEnd() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                   object: followedScroll?.contentView)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification,
                                                   object: followedDocument)
        followedScroll = nil
        followedDocument = nil
    }

    private func releaseEnd() {
        stopObservingEnd()
        isFollowingEnd = false
        endUpdateQueued = false
    }

    func cancel() {
        releaseEnd()
        revision += 1
        restoring = false
        readingAnchor = nil
    }

    func restoreAfterLayout(_ anchor: Anchor) {
        releaseEnd()
        readingAnchor = anchor
        restoring = true
        revision += 1
        let request = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == request else { return }
            defer {
                DispatchQueue.main.async { [weak self] in
                    if self?.revision == request { self?.restoring = false }
                }
            }
            guard let view = self.markers[anchor.id]?.view, !view.isHiddenOrHasHiddenAncestor,
                  let scroll = view.enclosingScrollView, let document = scroll.documentView else { return }
            scroll.layoutSubtreeIfNeeded()
            let visible = scroll.documentVisibleRect
            let delta = view.convert(view.bounds, to: document).minY - visible.minY - anchor.offset
            guard abs(delta) > 0.25 else { return }
            let limit = max(0, document.bounds.height - visible.height)
            let position = min(limit, max(0, visible.minY + delta))
            scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: position))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

struct TranscriptMarker: NSViewRepresentable {
    let id: Int
    let viewport: TranscriptViewport

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.setAccessibilityElement(false)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        if view.id != id { view.viewport?.remove(view, id: view.id) }
        view.id = id
        view.viewport = viewport
        viewport.register(view, id: id)
    }

    static func dismantleNSView(_ view: MarkerView, coordinator: ()) {
        view.viewport?.remove(view, id: view.id)
    }

    final class MarkerView: NSView {
        var id = 0
        weak var viewport: TranscriptViewport?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if id == Int.min { viewport?.layoutChanged() }
        }
    }
}

/// Where the chat is scrolled, to tell the reader scrolling from the session writing.
struct TranscriptScrollSpot: Equatable {
    let offset: CGFloat
    let height: CGFloat
    let viewportHeight: CGFloat
    let atEnd: Bool
}

/// Only user input changes whether subsequent transcript updates follow the end.
struct TranscriptScrollState {
    var following = true
    private(set) var interacting = false

    mutating func changePhase(_ phase: ScrollPhase, atEnd: Bool) -> Bool {
        let wasInteracting = interacting
        interacting = phase == .tracking || phase == .interacting || phase == .decelerating
        let starting = phase == .tracking || phase == .interacting
        if starting { following = false } else if wasInteracting, phase == .idle { following = atEnd }
        return starting
    }

    mutating func moved(atEnd: Bool) {
        if interacting { following = atEnd }
    }
}

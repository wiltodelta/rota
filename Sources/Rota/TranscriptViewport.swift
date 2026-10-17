import AppKit
import SwiftUI

/// SwiftUI's lazy estimates can move a message even while its ID stays selected.
/// These invisible markers restore the actual pixel offset after a transcript update.
@MainActor
final class TranscriptViewport {
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

    func register(_ view: NSView, id: Int) { markers[id] = WeakMarker(view: view) }

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
            guard requestedID == nil || requestedID == id,
                  let view = marker.view, view.window != nil,
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

    func cancel() {
        revision += 1
        restoring = false
        readingAnchor = nil
    }

    func restoreAfterLayout(_ anchor: Anchor) {
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
            guard let view = self.markers[anchor.id]?.view,
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
    }
}

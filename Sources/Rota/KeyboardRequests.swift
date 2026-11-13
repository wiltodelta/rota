import SwiftUI

/// Keyboard requests that cross views: the sidebar list hands focus to the message
/// field and pages the transcript beside it; the field hands focus back; the Session
/// menu reaches the open session's question and earlier messages.
@MainActor
@Observable
final class KeyboardRequests {
    struct Page: Equatable {
        let down: Bool
        let serial: Int
    }

    private(set) var composerFocus = 0
    private(set) var listFocus = 0
    private(set) var page: Page?
    private(set) var questionReveal = 0
    private(set) var earlierMessages = 0
    /// The open session whose transcript has earlier messages to load.
    private(set) var sessionWithEarlier: UUID?

    func revealQuestion() { questionReveal += 1 }
    func loadEarlierMessages() { earlierMessages += 1 }
    /// A closing view clears only its own session, so the next one's report survives.
    func setEarlierMessages(_ available: Bool, in session: UUID) {
        if available { sessionWithEarlier = session } else if sessionWithEarlier == session { sessionWithEarlier = nil }
    }
    func focusComposer() { composerFocus += 1 }
    func focusList() { listFocus += 1 }
    func scrollTranscript(down: Bool) { page = Page(down: down, serial: (page?.serial ?? 0) + 1) }
}

/// Up and Down through the menu bar panel's routines, as in a menu: the first
/// press highlights an end, and the highlight stops at the other end.
enum PanelHighlight {
    static func moved(_ current: String?, down: Bool, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return down ? ids.first : ids.last }
        return ids[min(ids.count - 1, max(0, index + (down ? 1 : -1)))]
    }
}

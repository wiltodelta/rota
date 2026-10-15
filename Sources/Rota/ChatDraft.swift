import Observation
import RotaCore

/// Unsent text and file selections survive navigation for this app launch.
@MainActor
@Observable
final class ChatDraft {
    let routineID: String

    init(routineID: String) { self.routineID = routineID }

    var text = ""
    var attachments: [ChatAttachment] = []
}

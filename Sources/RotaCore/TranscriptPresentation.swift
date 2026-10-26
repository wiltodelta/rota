import Foundation

/// Provider-generated user-role entries are service events, not human turns.
/// Keep their original text available, including when reading older journals.
public enum TranscriptService {
    public static func title(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[Request interrupted by user for tool use]" { return "Tool use interrupted" }
        return taskIDs(text).isEmpty ? nil : "Background task notification"
    }

    /// The chat's note while a finished turn leaves background tasks running.
    static func waiting(_ tasks: Int) -> String {
        "Waiting for \(tasks) background \(tasks == 1 ? "task" : "tasks")"
    }

    /// The background tasks a whole Claude task-notification envelope reports on; one can name several.
    static func taskIDs(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<task-notification>"), trimmed.hasSuffix("</task-notification>"),
              let document = try? XMLDocument(xmlString: trimmed, options: .nodeLoadExternalEntitiesNever),
              let root = document.rootElement(), root.name == "task-notification" else { return [] }
        return root.elements(forName: "task-id").compactMap(\.stringValue).filter { !$0.isEmpty }
    }
}

extension TranscriptItem {
    /// Presentation changes never rewrite saved history or change entry IDs.
    public var presented: TranscriptItem {
        var item = self
        if kind == .user, TranscriptService.title(text) != nil { item.kind = .status }
        if kind == .status, text.lowercased().hasPrefix("succeeded after ") {
            item.text = "Completed" + text.dropFirst("Succeeded".count)
        }
        return item
    }
}

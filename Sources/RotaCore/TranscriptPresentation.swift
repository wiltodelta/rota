import Foundation

/// Provider-generated user-role entries are service events, not human turns.
/// Keep their original text available, including when reading older journals.
public enum TranscriptService {
    public static func title(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[Request interrupted by user for tool use]" { return "Tool use interrupted" }
        guard trimmed.hasPrefix("<task-notification>"), trimmed.hasSuffix("</task-notification>"),
              let document = try? XMLDocument(xmlString: trimmed, options: .nodeLoadExternalEntitiesNever),
              let root = document.rootElement(), root.name == "task-notification",
              root.elements(forName: "task-id").first?.stringValue?.isEmpty == false else { return nil }
        return "Background task notification"
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

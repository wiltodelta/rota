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
    /// Some providers persist a signed thinking block without exposing its text.
    /// Keep it in history, but do not offer an empty disclosure in the chat.
    public var isEmptyReasoning: Bool {
        kind == .reasoning && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

/// Pure display ordering that never rewrites journal entries or alters their IDs.
public enum TranscriptOrder {
    /// Antigravity flushes a step's archived thinking when the response completes,
    /// after its streamed text. Pair Rota's own step IDs so thinking precedes its reply.
    public static func alignSameStepReasoning(_ items: [TranscriptItem]) -> [TranscriptItem] {
        var result = items
        var index = 0
        while index < result.count {
            guard let stem = antigravityTextStem(result[index]),
                  let match = matchingThinkingIndex(stem: stem, after: index, in: result) else {
                index += 1
                continue
            }
            let thinking = result[match]
            for pos in stride(from: match, to: index, by: -1) {
                result[pos] = result[pos - 1]
            }
            result[index] = thinking
            index += 2
        }
        return result
    }

    private static func antigravityTextStem(_ item: TranscriptItem) -> String? {
        guard item.kind == .agent, item.isComplete, let id = item.nativeID,
              id.hasPrefix("antigravity/"), id.hasSuffix("/text") else { return nil }
        return String(id.dropLast("/text".count))
    }

    private static func matchingThinkingIndex(stem: String, after start: Int, in items: [TranscriptItem]) -> Int? {
        let target = stem + "/thinking"
        for candidate in (start + 1)..<items.count {
            let kind = items[candidate].kind
            if kind == .user || kind == .agent { return nil }
            if kind == .reasoning, items[candidate].nativeID == target { return candidate }
        }
        return nil
    }
}

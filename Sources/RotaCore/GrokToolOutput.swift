import Foundation

/// ACP tool results use content blocks for text and diff blocks for edits.
/// Both the live connection and terminal archive preserve the same display text.
enum GrokToolOutput {
    static func text(_ block: [String: Any]) -> String? {
        switch block["type"] as? String {
        case "content":
            return (block["content"] as? [String: Any])?["text"] as? String
        case "diff":
            guard let path = block["path"] as? String else { return nil }
            let before = block["oldText"] as? String ?? ""
            let after = block["newText"] as? String ?? ""
            return path + "\nBefore:\n" + before + "\nAfter:\n" + after
        default: return nil
        }
    }
}

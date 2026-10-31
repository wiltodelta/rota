import Foundation

/// Ordered tool content, carried inside existing output entries. Plain text stays plain text.
public struct ToolOutput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image, diff }

    public struct Part: Codable, Equatable, Sendable {
        public var kind: Kind
        public var text: String
        public var path: String?
    }

    public var parts: [Part]
    private static let marker = "[Rota tool output v1]\n"

    public var encoded: String {
        guard parts.contains(where: { $0.kind != .text }), let data = try? JSONEncoder().encode(self) else {
            return parts.map(\.text).joined(separator: "\n")
        }
        return Self.marker + lossyUTF8(data)
    }

    public static func decode(_ text: String) -> ToolOutput? {
        guard text.hasPrefix(marker) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst(marker.count).utf8))
    }

    public var readable: String {
        parts.map { part in
            switch part.kind {
            case .text: return part.text
            case .image: return "[image: \(part.path ?? "Tool image")]"
            case .diff: return (part.path ?? "Changes") + "\n" + part.text
            }
        }.joined(separator: "\n")
    }

    static func content(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        let parts = (value as? [[String: Any]] ?? []).flatMap(block)
        return parts.isEmpty ? nil : ToolOutput(parts: parts).encoded
    }

    static func image(_ url: String, label: String = "Tool image") -> String {
        ToolOutput(parts: [.init(kind: .image, text: url, path: label)]).encoded
    }

    private static func block(_ block: [String: Any]) -> [Part] {
        switch block["type"] as? String {
        case "text", "input_text", "inputText":
            return (block["text"] as? String).map { [.init(kind: .text, text: $0)] } ?? []
        case "image", "input_image", "inputImage":
            let source = block["source"] as? [String: Any] ?? block
            if let data = source["data"] as? String,
               let mime = source["media_type"] as? String ?? source["mimeType"] as? String {
                return [.init(kind: .image, text: "data:\(mime);base64,\(data)", path: "Tool image")]
            }
            let image = block["image_url"] as? [String: Any]
            let url = source["url"] as? String ?? block["imageUrl"] as? String
                ?? block["image_url"] as? String ?? image?["url"] as? String ?? block["uri"] as? String
            if let url {
                return [.init(kind: .image, text: url, path: "Tool image")]
            }
            return [.init(kind: .text, text: unsupported(block))]
        case "resource":
            return ((block["resource"] as? [String: Any])?["text"] as? String)
                .map { [.init(kind: .text, text: $0)] }
                ?? [.init(kind: .text, text: unsupported(block))]
        case "resource_link":
            let metadata = details(block)
            return [.init(kind: .text, text: metadata.isEmpty ? unsupported(block) : metadata.joined(separator: "\n"))]
        default: return [.init(kind: .text, text: unsupported(block))]
        }
    }

    /// Preserve display metadata without serializing opaque binary data or provider-private fields.
    static func unsupported(_ block: [String: Any]) -> String {
        let type = block["type"] as? String ?? "unknown"
        let resource = block["resource"] as? [String: Any] ?? block
        return (["Couldn't display tool content (\(type))."] + details(resource)).joined(separator: "\n")
    }

    private static func details(_ block: [String: Any]) -> [String] {
        var seen = Set<String>()
        return ["title", "name", "mimeType", "uri", "text"].compactMap { key in
            guard let value = block[key] as? String, !value.isEmpty, seen.insert(value).inserted else { return nil }
            if key == "uri", value.lowercased().hasPrefix("data:") { return nil }
            return value
        }
    }
}

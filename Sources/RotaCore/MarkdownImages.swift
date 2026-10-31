import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct MarkdownImageReference: Equatable, Sendable {
    public var url: URL
    public var alt: String

    public init(url: URL, alt: String) {
        self.url = url
        self.alt = alt
    }

    public enum Content: Equatable, Sendable {
        case text(AttributedString)
        case image(MarkdownImageReference)
    }

    /// Foundation owns Markdown escaping, URL parsing, and inline formatting.
    public static func content(_ source: String) -> [Content] {
        let parsed = inlineMarkdown(source)
        var result: [Content] = []
        for run in parsed.runs {
            let text = AttributedString(parsed[run.range])
            if let url = run.imageURL {
                result.append(.image(.init(url: url, alt: String(text.characters))))
            } else if case .text(var previous) = result.last {
                previous += text
                result[result.count - 1] = .text(previous)
            } else {
                result.append(.text(text))
            }
        }
        return result
    }

    public static func references(in blocks: [MarkdownBlock]) -> [MarkdownImageReference] {
        blocks.flatMap { block -> [MarkdownImageReference] in
            let source: String
            switch block {
            case .paragraph(let text), .heading(_, let text), .listItem(_, let text, _): source = text
            case .table(let table): source = (table.headers + table.rows.flatMap { $0 }).joined(separator: "\n")
            case .code: return []
            }
            return content(source).compactMap { if case .image(let ref) = $0 { ref } else { nil } }
        }
    }
}

/// Copies local proof images into the existing session attachment store.
/// The original Markdown and source files remain unchanged. Remote URLs are never fetched.
public struct SessionImageStore: Sendable {
    private let attachments: ChatAttachmentStore
    private let workingDirectory: URL?
    private var indexURL: URL { attachments.folder.appendingPathComponent("images.json") }

    public init(log: URL, workingDirectory: URL? = nil) {
        attachments = ChatAttachmentStore(log: log)
        self.workingDirectory = workingDirectory
    }

    private func index() -> [String: ChatAttachment] {
        (try? JSONDecoder().decode([String: ChatAttachment].self, from: Data(contentsOf: indexURL))) ?? [:]
    }

    private func key(_ url: URL, itemID: Int?) -> String {
        (itemID.map { "\($0)|" } ?? "") + url.absoluteString
    }

    public func archived(_ url: URL, itemID: Int? = nil) -> URL? {
        guard let file = index()[key(url, itemID: itemID)],
              file.url.resolvingSymlinksInPath().path
                .hasPrefix(attachments.folder.resolvingSymlinksInPath().path + "/"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file.url
    }

    private func source(for url: URL) -> URL? {
        if url.isFileURL { return url }
        guard url.scheme == nil else { return nil }
        if url.path.hasPrefix("/") { return URL(fileURLWithPath: url.path) }
        return workingDirectory?.appendingPathComponent(url.path)
    }

    /// Replace inline image bytes with a durable local reference before journaling.
    func preserveOutput(_ text: String, itemID: Int?) throws -> String {
        guard var output = ToolOutput.decode(text) else { return text }
        var references: [MarkdownImageReference] = []
        for index in output.parts.indices where output.parts[index].kind == .image {
            let value = output.parts[index].text
            if value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","),
               value[..<comma].hasSuffix(";base64"),
               let data = Data(base64Encoded: String(value[value.index(after: comma)...])) {
                let image = CGImageSourceCreateWithData(data as CFData, nil)
                let suffix = image.flatMap { CGImageSourceGetType($0) }
                    .flatMap { UTType($0 as String)?.preferredFilenameExtension }
                let name = "tool-image" + (suffix.map { "." + $0 } ?? "")
                let file = try attachments.stage(data, name: name)
                output.parts[index].text = file.url.absoluteString
            } else if let url = URL(string: value) {
                references.append(.init(url: url, alt: output.parts[index].path ?? "Tool image"))
            }
        }
        try capture(references, itemID: itemID)
        return output.encoded
    }

    public func capture(_ references: [MarkdownImageReference], itemID: Int? = nil) throws {
        guard !references.isEmpty else { return }
        var saved = index()
        var created: [ChatAttachment] = []
        do {
            for reference in references {
                let identity = key(reference.url, itemID: itemID)
                if let existing = saved[identity],
                   FileManager.default.fileExists(atPath: existing.path) { continue }
                guard let source = source(for: reference.url),
                      FileManager.default.fileExists(atPath: source.path) else { continue }
                guard let file = try attachments.stage([source]).first else { continue }
                saved[identity] = file
                created.append(file)
            }
            if !created.isEmpty { try JSONEncoder().encode(saved).write(to: indexURL, options: .atomic) }
        } catch {
            for file in created { try? attachments.discard(file) }
            throw error
        }
    }
}

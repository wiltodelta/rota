import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A local attachment retained with its session, never inside the working repository.
public struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var url: URL
    public var name: String
    public var mimeType: String
    public var size: Int

    public var isImage: Bool { mimeType.hasPrefix("image/") }
    var isNativeImage: Bool { ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mimeType) }

    public static func inspect(_ url: URL) throws -> ChatAttachment {
        guard url.isFileURL else { throw AttachmentError.invalid("Choose a local file.") }
        let sourceURL = url.resolvingSymlinksInPath()
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AttachmentError.invalid("Choose files, not folders.") }
        let size = values.fileSize ?? 0
        guard size <= 20_000_000 else {
            throw AttachmentError.invalid("\(url.lastPathComponent) exceeds the 20 MB attachment limit.")
        }
        var mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if mime.hasPrefix("image/") { mime = "application/octet-stream" }
        if let image = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), let type = CGImageSourceGetType(image) {
            mime = UTType(type as String)?.preferredMIMEType ?? mime
        }
        return ChatAttachment(id: UUID().uuidString, url: url, name: url.lastPathComponent, mimeType: mime, size: size)
    }
}

public enum AttachmentError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

public struct ChatMessage: Equatable, Sendable {
    public var text: String
    public var attachments: [ChatAttachment]

    public init(text: String, attachments: [ChatAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    /// Terminal and text-only steering protocols refer to retained local files.
    public var fileReferenceText: String { text(referencing: attachments) }

    private func text(referencing files: [ChatAttachment]) -> String {
        guard !files.isEmpty else { return text }
        let references = files.map { "\($0.name): \($0.url.path)" }.joined(separator: "\n")
        return [text, "Attached files:\n" + references].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Codex accepts native local images on both turn/start and turn/steer.
    func codexInput() -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        let value = text(referencing: attachments.filter { !$0.isNativeImage })
        if !value.isEmpty { blocks.append(["type": "text", "text": value]) }
        blocks += attachments.filter(\.isNativeImage).map { ["type": "localImage", "path": $0.url.path] }
        return blocks
    }

    func claudeContent() throws -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        let value = text(referencing: attachments.filter { !$0.isNativeImage })
        if !value.isEmpty { blocks.append(["type": "text", "text": value]) }
        for image in attachments where image.isNativeImage {
            let data = try Data(contentsOf: image.url)
            blocks.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType,
                                                          "data": data.base64EncodedString()]])
        }
        return blocks
    }

    /// ACP image blocks are used only when initialize advertises the image prompt capability.
    func acpContent(images: Bool) throws -> [[String: Any]] {
        guard images else { return [["type": "text", "text": fileReferenceText]] }
        var blocks: [[String: Any]] = []
        let value = text(referencing: attachments.filter { !$0.isNativeImage })
        if !value.isEmpty { blocks.append(["type": "text", "text": value]) }
        for image in attachments where image.isNativeImage {
            blocks.append(["type": "image", "mimeType": image.mimeType,
                           "data": try Data(contentsOf: image.url).base64EncodedString()])
        }
        return blocks
    }

    /// The text that Claude echoes alongside its native image content.
    var claudeText: String { text(referencing: attachments.filter { !$0.isNativeImage }) }
}

public enum ChatAttachmentStore {
    public static func retain(_ message: ChatMessage, log: URL, messageID: String) throws -> ChatMessage {
        guard !message.attachments.isEmpty else { return message }
        guard message.attachments.count <= 10 else {
            throw AttachmentError.invalid("Attach up to 10 files per message.")
        }
        let inspected = try message.attachments.map { try ChatAttachment.inspect($0.url) }
        guard inspected.reduce(0, { $0 + $1.size }) <= 50_000_000 else {
            throw AttachmentError.invalid("Attachments exceed the 50 MB total limit.")
        }
        let folder = log.deletingPathExtension().appendingPathExtension("attachments")
            .appendingPathComponent(messageID)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var retained: [ChatAttachment] = []
            for (original, checked) in zip(message.attachments, inspected) {
                guard UUID(uuidString: original.id) != nil else {
                    throw AttachmentError.invalid("Invalid attachment id.")
                }
                let destination = folder.appendingPathComponent(original.id).appendingPathComponent(checked.name)
                try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                try manager.copyItem(at: original.url.resolvingSymlinksInPath(), to: destination)
                var attachment = checked
                attachment.id = original.id
                attachment.url = destination
                retained.append(attachment)
            }
            return ChatMessage(text: message.text, attachments: retained)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }
}

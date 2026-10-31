import Foundation

public struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// A message remains text on every harness. Rota renders its versioned file manifest as chips.
public struct ChatMessage: Equatable, Sendable {
    public let text: String
    public let attachments: [ChatAttachment]
    private static let marker = "\n\n[Rota attachments v1]\n"

    public init(text: String, attachments: [ChatAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public func encoded() throws -> String {
        guard !attachments.isEmpty else { return text }
        let data = try JSONEncoder().encode(attachments)
        return text + Self.marker + lossyUTF8(data)
    }

    public static func decode(_ message: String) -> ChatMessage {
        guard let marker = message.range(of: Self.marker, options: .backwards),
              let files = try? JSONDecoder().decode([ChatAttachment].self,
                                                   from: Data(message[marker.upperBound...].utf8)),
              !files.isEmpty, files.allSatisfy({ $0.path.hasPrefix("/") && !$0.name.isEmpty }) else {
            return ChatMessage(text: message)
        }
        return ChatMessage(text: String(message[..<marker.lowerBound]), attachments: files)
    }
}

/// Copies selected files, never moves them. Sent copies share their session's retention.
public struct ChatAttachmentStore: Sendable {
    public let folder: URL

    public init(log: URL) { folder = Self.folder(for: log) }
    public static func folder(for log: URL) -> URL { log.appendingPathExtension("attachments") }

    private func validateFolder() throws {
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              folder.resolvingSymlinksInPath().deletingLastPathComponent().path
                == folder.deletingLastPathComponent().resolvingSymlinksInPath().path else {
            throw AttachmentError.unsafeFolder
        }
    }

    public func stage(_ urls: [URL]) throws -> [ChatAttachment] {
        let manager = FileManager.default
        try validateFolder()
        var created: [URL] = []
        do {
            return try urls.map { source in
                guard source.isFileURL else { throw AttachmentError.notAFile }
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let values = try source.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw AttachmentError.notAFile }
                let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                created.append(directory)
                let target = directory.appendingPathComponent(source.lastPathComponent)
                try manager.copyItem(at: source, to: target)
                return ChatAttachment(name: source.lastPathComponent, path: target.path)
            }
        } catch {
            for directory in created { try? manager.removeItem(at: directory) }
            throw error
        }
    }

    /// Inline tool images are owned by this session from the moment they are saved.
    func stage(_ data: Data, name: String) throws -> ChatAttachment {
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try validateFolder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        do { try data.write(to: target, options: .atomic) } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return ChatAttachment(name: name, path: target.path)
    }

    /// Only a draft's own UUID folder may be discarded, never the selected original.
    public func discard(_ attachment: ChatAttachment) throws {
        let directory = attachment.url.deletingLastPathComponent()
        guard UUID(uuidString: directory.lastPathComponent) != nil,
              directory.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              directory.resolvingSymlinksInPath().deletingLastPathComponent().path
                == folder.resolvingSymlinksInPath().path else { throw AttachmentError.unsafeFolder }
        try FileManager.default.removeItem(at: directory)
    }
}

public enum AttachmentError: LocalizedError {
    case notAFile, unsafeFolder
    public var errorDescription: String? {
        switch self {
        case .notAFile: "Choose regular files, not folders or web links."
        case .unsafeFolder: "The attachment folder is not owned by this session."
        }
    }
}

import Foundation
import UniformTypeIdentifiers
import ImageIO

/// Native images are additive: every harness still receives the durable attachment manifest.
enum HarnessInput {
    // Stay below partner API base64 limits across the entire inline payload; larger files remain references.
    private static let inlineBudget = 3_500_000

    static func blocks(_ message: String, for mode: LaunchMode) -> [[String: Any]] {
        var blocks: [[String: Any]] = [["type": "text", "text": message]]
        guard mode.capabilities.images != .fileReferences else { return blocks }
        var inlineBytes = 0
        let formats = mode == .grokACP ? ["image/png", "image/jpeg"]
            : ["image/png", "image/jpeg", "image/gif", "image/webp"]
        for file in ChatMessage.decode(message).attachments {
            guard let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 20 * 1024 * 1024,
                  let image = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                  let identifier = CGImageSourceGetType(image),
                  let mime = UTType(identifier as String)?.preferredMIMEType,
                  formats.contains(mime),
                  CGImageSourceGetCount(image) > 0 else { continue }
            if mode == .codexDaemon, mime == "image/gif", CGImageSourceGetCount(image) > 1 { continue }
            if mode.capabilities.images == .localPath {
                blocks.append(["type": "localImage", "path": file.path])
            } else if size <= inlineBudget - inlineBytes, let data = try? Data(contentsOf: file.url),
                      data.count <= inlineBudget - inlineBytes {
                inlineBytes += data.count
                let encoded = data.base64EncodedString()
                if mode == .claudeStream {
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": encoded]])
                } else {
                    blocks.append(["type": "image", "mimeType": mime, "data": encoded])
                }
            }
        }
        return blocks
    }
}

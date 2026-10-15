import AppKit
import ImageIO
import RotaCore
import SwiftUI

/// Small previews use ImageIO downsampling rather than decoding the full image into the chat.
@MainActor
enum AttachmentPreview {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 32_000_000
        return cache
    }()

    static func image(_ file: ChatAttachment, pixels: Int = 560) -> NSImage? {
        guard file.isImage, file.url.isFileURL else { return nil }
        let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(file.url.absoluteString)|\(pixels)|\(stamp)|\(values?.fileSize ?? 0)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else { return nil }
        let preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(preview, forKey: key, cost: image.bytesPerRow * image.height)
        return preview
    }
}

/// The composer's retained selection; removing a chip never deletes the user's file.
struct ChatAttachmentStrip: View {
    let files: [ChatAttachment]
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        if let image = AttachmentPreview.image(file, pixels: 128) {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: 48, height: 48)
                                .accessibilityLabel("Preview of " + file.name)
                        } else {
                            Image(systemName: "doc").interfaceFont(size: 24)
                                .frame(width: 32, height: 48)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).interfaceFont(.callout).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                .interfaceFont(.caption).foregroundStyle(Color.secondaryText)
                        }
                        .frame(maxWidth: 140, alignment: .leading)
                        Button { remove(file.id) } label: {
                            Image(systemName: "xmark")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove " + file.name)
                            .accessibilityIdentifier("removeAttachment-" + file.id)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .help(file.name)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("attachmentStrip")
    }
}

import AppKit
import ImageIO
import RotaCore
import SwiftUI

extension EnvironmentValues {
    @Entry var sessionLogURL: URL?
    @Entry var sessionImageItemID: Int?
}

/// Text and proof images retain their order inside a Markdown block.
struct MarkdownInlineView: View {
    @Environment(\.interfaceScale) private var metrics
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            ForEach(Array(MarkdownImageReference.content(source).enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text): Text(text)
                case .image(let reference): MarkdownImageView(reference: reference)
                }
            }
        }
    }
}

private struct MarkdownImageView: View {
    @Environment(\.sessionLogURL) private var log
    @Environment(\.sessionImageItemID) private var itemID
    @Environment(\.interfaceScale) private var metrics
    let reference: MarkdownImageReference
    @State private var image: NSImage?
    @State private var loading = true
    @State private var resolvedURL: URL?

    private struct Source: Hashable, Sendable {
        let log: URL?
        let itemID: Int?
        let original: URL
    }

    private var source: Source { Source(log: log, itemID: itemID, original: reference.url) }
    private var url: URL { resolvedURL ?? reference.url }

    private var label: String { reference.alt.isEmpty ? "Image" : reference.alt }

    private var placeholder: String {
        if loading { return "Loading image…" }
        return url.isFileURL || url.scheme == nil ? "Image unavailable" : "External image"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            if let image {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: metrics.points(480), minHeight: metrics.points(28),
                               maxHeight: metrics.points(280), alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: metrics.points(6)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open image: " + label)
                .accessibilityIdentifier("markdownImage")
            } else {
                Label(placeholder, systemImage: "photo")
                    .foregroundStyle(Color.secondaryText)
                    .accessibilityIdentifier("markdownImageUnavailable")
            }
            HStack(spacing: metrics.points(6)) {
                Text(label).lineLimit(2)
                if image == nil, url.scheme == "https" || url.scheme == "http" {
                    Link("Open Image", destination: url)
                        .frame(minHeight: metrics.points(20))
                }
            }
            .interfaceFont(.caption)
            .foregroundStyle(Color.secondaryText)
        }
        .help(url.isFileURL ? url.path : reference.url.absoluteString)
        .task(id: source) {
            image = nil
            loading = true
            resolvedURL = nil
            let source = source
            let loaded = await Task.detached(priority: .utility) {
                var url = source.original
                if let log = source.log,
                   let saved = SessionImageStore(log: log).archived(url, itemID: source.itemID) {
                    url = saved
                } else if url.scheme == nil, url.path.hasPrefix("/") {
                    url = URL(fileURLWithPath: url.path)
                }
                var thumbnail: CGImage?
                if url.isFileURL, let image = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
                }
                return (url, thumbnail)
            }.value
            guard !Task.isCancelled else { return }
            resolvedURL = loaded.0
            image = loaded.1.map { NSImage(cgImage: $0, size: .zero) }
            loading = false
        }
    }
}

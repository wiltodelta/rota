import AppKit
import RotaCore
import SwiftUI

struct AttachmentChips: View {
    @Environment(\.interfaceScale) private var metrics
    let attachments: [ChatAttachment]
    var remove: ((ChatAttachment) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: metrics.points(8)) {
                ForEach(attachments) { attachment in
                    HStack(spacing: metrics.points(4)) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
                        } label: {
                            HStack(spacing: metrics.points(4)) {
                                Image(systemName: "doc")
                                Text(attachment.name).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: metrics.points(160))
                            }
                            .frame(minHeight: metrics.points(20))
                        }
                        .help("Show \(attachment.name) in Finder")
                        if let remove {
                            Button { remove(attachment) } label: {
                                Image(systemName: "xmark").frame(width: metrics.points(20), height: metrics.points(20))
                            }
                            .help("Remove \(attachment.name)")
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                    }
                    .buttonStyle(.borderless)
                    .interfaceFont(.caption)
                    .foregroundStyle(Color.secondaryText)
                    .padding(.horizontal, metrics.points(6))
                    .padding(.vertical, metrics.points(4))
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: metrics.points(8)))
                    .accessibilityIdentifier("attachment-\(attachment.name)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: metrics.points(32))
    }
}

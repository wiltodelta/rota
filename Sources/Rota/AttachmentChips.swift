import AppKit
import RotaCore
import SwiftUI

struct AttachmentChips: View {
    let attachments: [ChatAttachment]
    var remove: ((ChatAttachment) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                Text(attachment.name).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: 160)
                            }
                            .frame(minHeight: 20)
                        }
                        .help("Show \(attachment.name) in Finder")
                        if let remove {
                            Button { remove(attachment) } label: {
                                Image(systemName: "xmark").frame(width: 20, height: 20)
                            }
                            .help("Remove \(attachment.name)")
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("attachment-\(attachment.name)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 32)
    }
}

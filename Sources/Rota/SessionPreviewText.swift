import RotaCore
import SwiftUI

/// A session's list excerpt. `TranscriptSessionReader.followPreview` reads and renders it off the
/// main thread; the body only shows the result.
struct SessionPreviewText: View {
    let record: RunRecord
    @State private var preview: String?
    @State private var reader = TranscriptSessionReader()

    var body: some View {
        Text(verbatim: preview ?? SessionPreview.text(for: record, snapshot: nil))
            .task(id: record) {
                await reader.followPreview(of: record) { next in
                    if preview != next { preview = next }
                }
            }
    }
}

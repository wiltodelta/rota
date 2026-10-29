import RotaCore
import SwiftUI

/// A one-session harness choice, shared by the header and the usage-limit suggestion.
struct SessionRestartMenu: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    var identifier = "restartSession"
    @State private var restarting = false

    var body: some View {
        Menu {
            ForEach(Harness.agents.filter { $0 != record.harness }) { harness in
                Button(harness.title) {
                    restarting = true
                    Task {
                        defer { restarting = false }
                        if let next = await model.scheduler.restart(record, with: harness) {
                            model.selection = .session(next.id)
                        }
                    }
                }
                .disabled(!FileManager.default.isExecutableFile(atPath: model.scheduler.executable(harness)))
                .accessibilityIdentifier("restartWith-\(harness.rawValue)")
            }
        } label: {
            InterfaceButtonLabel(title: "Restart with…", symbol: "arrow.triangle.2.circlepath")
        }
        .disabled(restarting || !model.scheduler.canRestart(record))
        .help("Start a new session with this conversation's context. Uses the chosen harness's default model.")
        .accessibilityIdentifier(identifier)
    }
}

struct SessionLimitBanner: View {
    @Environment(\.interfaceScale) private var metrics
    let record: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(8)) {
            Text("Usage limit reached")
                .interfaceFont(.callout).fontWeight(.semibold)
            Text("Continue in another harness. This routine's scheduled harness stays the same.")
                .interfaceFont(.callout)
            SessionRestartMenu(record: record, identifier: "restartSessionAfterLimit").fixedSize()
        }
        .padding(metrics.points(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: metrics.points(10)))
        .padding(.horizontal, metrics.points(24))
        .padding(.top, metrics.points(12))
        .frame(maxWidth: metrics.points(760))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionUsageLimit")
    }
}

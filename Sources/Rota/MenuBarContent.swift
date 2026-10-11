import RotaCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    private var routines: [Routine] {
        model.scheduler.routines.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled }
            return (lhs.nextFire ?? .distantFuture) < (rhs.nextFire ?? .distantFuture)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if routines.isEmpty {
                Text("No routines yet")
                    .foregroundStyle(Color.panelSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                // Rows at their own height; a ScrollView only once they would not
                // fit, because one is greedy and stretched the panel to its limit.
                let rows = VStack(spacing: 2) {
                    ForEach(routines) { routine in
                        MenuRoutineRow(routine: routine) {
                            model.showMainWindow(selecting: model.latest(of: routine.id))
                        }
                    }
                }
                .padding(6)
                if routines.count > 9 {
                    ScrollView { rows }.frame(height: 420)
                } else {
                    rows
                }
            }
            let records = model.scheduler.allRecords()
            let waiting = records.filter { $0.attention != nil }
            if let newest = waiting.first {
                Divider()
                Button {
                    model.showMainWindow(selecting: .session(newest.id))
                } label: {
                    let count = waiting.count == 1 ? "1 session needs" : "\(waiting.count) sessions need"
                    Label("\(count) your reply", systemImage: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(10)
                .help("Open the newest session waiting for you")
                .accessibilityIdentifier("panelNeedsReply")
            }
            let unread = records.filter(\.isUnread)
            if let newest = unread.first {
                Divider()
                Button {
                    model.showMainWindow(selecting: .session(newest.id))
                } label: {
                    Label(unread.count == 1 ? "1 unread session" : "\(unread.count) unread sessions",
                          systemImage: "tray.full")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(10)
                .help("Open the newest unread session")
            }
            if let version = Updater.shared.pendingVersion {
                Divider()
                Button("Update to \(version) available") { Updater.shared.checkForUpdates() }
                    .buttonStyle(.borderless)
                    .padding(10)
            }
            Divider()
            HStack {
                Button("Open Rota") { model.showMainWindow() }
                Spacer()
                Button("Settings", systemImage: "gearshape") { model.showSettings() }
                    .labelStyle(.iconOnly)
                    .help("Settings")
                Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .help("Quit Rota")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 340)
    }
}

private struct MenuRoutineRow: View {
    @Environment(AppModel.self) private var model
    let routine: Routine
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let running = model.scheduler.active[routine.id] != nil
        HStack(spacing: 8) {
            StatusDot(routine: routine)
            VStack(alignment: .leading, spacing: 1) {
                Text(routine.name).lineLimit(1)
                Text(subtitle(running: running))
                    .font(.caption)
                    .foregroundStyle(Color.panelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    if running {
                        model.scheduler.stop(routine.id)
                    } else {
                        model.scheduler.run(routine, trigger: .manual)
                    }
                } label: {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(running ? "Stop" : "Run now")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }

    private func subtitle(running: Bool) -> String {
        if running { return "Running on \(routine.harness.title)" }
        guard routine.enabled, let next = routine.nextFire else { return "\(routine.harness.title), paused" }
        return "\(routine.harness.title), next run \(NextRunFormat.string(next))"
    }
}

/// Running, last run failed, last run fine, or off.
struct StatusDot: View {
    @Environment(AppModel.self) private var model
    let routine: Routine

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var last: RunRecord? {
        _ = model.scheduler.historyVersion
        // A skipped slot says nothing about how the routine is doing.
        return model.scheduler.history.records(for: routine.id).first { !$0.isSkip }
    }

    private var color: Color {
        if model.scheduler.active[routine.id] != nil { return .blue }
        if last?.outcome.isFailure == true { return .red }
        return routine.enabled ? .green : .secondary.opacity(0.5)
    }

    private var label: String {
        if model.scheduler.active[routine.id] != nil { return "Running" }
        if let last, last.outcome.isFailure { return "Last run: \(last.outcome.title)" }
        return routine.enabled ? "On schedule" : "Paused"
    }
}

extension Color {
    /// Secondary text on the glass panel. The system `.secondary` measured under
    /// 4.5:1 on Liquid Glass in watch-me-sleep's identical panel; this keeps the
    /// softer look at a readable contrast.
    static let panelSecondary = Color.primary.opacity(0.66)
}

/// When a routine runs next: relative within a day ("in 3 hours"), else a short
/// date without the year ("Mon, Oct 12, 10:15 AM"), which fits one line.
enum NextRunFormat {
    static func string(_ date: Date, now: Date = .now) -> String {
        if date.timeIntervalSince(now) < 24 * 3600 {
            return date.formatted(.relative(presentation: .numeric))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

import AppKit
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
                    .foregroundStyle(Color.secondaryText)
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
                    ScrollView { rows }
                        .frame(height: min(420, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
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
                    // Orange marks it; the text stays primary, since orange text is unreadable on light glass.
                    Label {
                        Text("\(count) your reply").fontWeight(.medium)
                    } icon: {
                        Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                    }
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
                Button { Updater.shared.checkForUpdates() } label: {
                    HStack(spacing: 8) {
                        Label("Install Update\u{2026}", systemImage: "arrow.down.circle")
                        Spacer(minLength: 8)
                        Text("Version \(version) is available").foregroundStyle(Color.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
            Divider()
            HStack(spacing: 16) {
                // Opens a window, so the title ends with an ellipsis (HIG).
                Button { model.showSettings() } label: {
                    Label("Settings\u{2026}", systemImage: "gearshape").interfaceFooterTarget()
                }
                Button { model.showMainWindow() } label: { Text("Open Rota").interfaceFooterTarget() }
                Spacer(minLength: 8)
                Button { NSApp.terminate(nil) } label: { Text("Quit").interfaceFooterTarget() }
                    .help("Quit Rota")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondaryText)
            .interfaceFont(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(width: min(340, (NSScreen.main?.visibleFrame.width ?? 1024) - 16))
        // Protect text contrast over extreme backdrops while retaining the native glass rim.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
    }
}

private struct MenuRoutineRow: View {
    @Environment(AppModel.self) private var model
    let routine: Routine
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let running = model.scheduler.active[routine.id] != nil
        let toggleRun = {
            if running {
                model.scheduler.stop(routine.id)
            } else {
                model.scheduler.run(routine, trigger: .manual)
            }
        }
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    StatusDot(routine: routine)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(routine.name).lineLimit(1)
                        Text(subtitle(running: running))
                            .interfaceFont(.caption)
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(routine.name)
            .accessibilityValue(spokenState(running: running))
            .accessibilityHint("Opens its latest session")
            .accessibilityAction(named: running ? "Stop" : "Run Now", toggleRun)
            if hovering {
                Button(action: toggleRun) {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(running ? "Stop" : "Run now")
                .accessibilityLabel("\(running ? "Stop" : "Run") \(routine.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// The subtitle and the dot's state, the state once when the subtitle already says it.
    private func spokenState(running: Bool) -> String {
        let text = subtitle(running: running)
        let status = StatusDot.status(of: routine, in: model.scheduler)
        return text.localizedCaseInsensitiveContains(status) ? text : "\(text), \(status)"
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
        // One history read for both the colour and the spoken state.
        let last = Self.lastRun(of: routine, in: model.scheduler)
        Circle()
            .fill(color(last))
            .frame(width: 8, height: 8)
            .accessibilityLabel(Self.status(of: routine, in: model.scheduler, last: last))
    }

    /// The latest run that is not a skip: a skipped slot says nothing about how the
    /// routine is doing. Reads the routine's history file.
    static func lastRun(of routine: Routine, in scheduler: Scheduler) -> RunRecord? {
        _ = scheduler.historyVersion
        return scheduler.history.records(for: routine.id).first { !$0.isSkip }
    }

    private func color(_ last: RunRecord?) -> Color {
        if model.scheduler.active[routine.id] != nil { return .blue }
        if last?.outcome.isFailure == true { return .red }
        return routine.enabled ? .green : Color.secondary.opacity(0.5)
    }

    static func status(of routine: Routine, in scheduler: Scheduler) -> String {
        status(of: routine, in: scheduler, last: lastRun(of: routine, in: scheduler))
    }

    private static func status(of routine: Routine, in scheduler: Scheduler, last: RunRecord?) -> String {
        if scheduler.active[routine.id] != nil { return "Running" }
        if let last, last.outcome.isFailure { return "Last run: \(last.outcome.title)" }
        return routine.enabled ? "On schedule" : "Paused"
    }
}

extension Color {
    /// Secondary text the app draws. The system `.secondary` measured under 4.5:1
    /// on Liquid Glass in watch-me-sleep's identical panel and on translate-like-me's
    /// settings forms; this keeps the softer look at a readable contrast
    /// (claude-config docs/macos-apps.md).
    static let secondaryText = Color.primary.opacity(0.66)

    /// Warning and error text. The system orange and red measure 2.3:1 and
    /// 3.6:1 on a light window, under the 4.5:1 text needs; these are Apple's
    /// increased-contrast shades in light mode and the system colors in dark,
    /// where those already pass.
    static let warningText = adaptive(light: NSColor(srgbRed: 201 / 255, green: 52 / 255, blue: 0, alpha: 1),
                                      dark: .systemOrange)
    static let errorText = adaptive(light: NSColor(srgbRed: 215 / 255, green: 0, blue: 21 / 255, alpha: 1),
                                    dark: .systemRed)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
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

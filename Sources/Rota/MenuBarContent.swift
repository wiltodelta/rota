import AppKit
import RotaCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    private var routines: [Routine] {
        RoutineOrder.byNextRun(model.scheduler.routines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if routines.isEmpty {
                Text("No routines yet")
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.points(20))
            } else {
                // Rows at their own height; a ScrollView only once they would not
                // fit, because one is greedy and stretched the panel to its limit.
                let rows = VStack(spacing: metrics.points(2)) {
                    ForEach(routines) { routine in
                        MenuRoutineRow(routine: routine) {
                            model.showMainWindow(selecting: model.latest(of: routine.id))
                        }
                    }
                }
                .padding(metrics.points(6))
                if routines.count > 9 {
                    ScrollView { rows }.frame(height: metrics.points(420))
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
                    let repliesOnly = waiting.allSatisfy { model.scheduler.canMessage($0) }
                    let count = waiting.count == 1 ? "1 session needs" : "\(waiting.count) sessions need"
                    // Orange marks it; the text stays primary, since orange text is unreadable on light glass.
                    Label {
                        Text("\(count) your \(repliesOnly ? "reply" : "attention")")
                            .fontWeight(.medium)
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(metrics.points(10))
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
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(metrics.points(10))
                .help("Open the newest unread session")
            }
            if let version = Updater.shared.pendingVersion {
                Divider()
                Button { Updater.shared.checkForUpdates() } label: {
                    HStack {
                        Label("Install Update\u{2026}", systemImage: "arrow.down.circle")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Text("Version \(version) is available").foregroundStyle(Color.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(metrics.points(10))
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics.points(16)) {
                    openButton
                    Spacer()
                    settingsButton
                    quitButton
                }
                VStack(alignment: .leading, spacing: metrics.points(4)) {
                    openButton
                    HStack {
                        settingsButton
                        Spacer()
                        quitButton
                    }
                }
            }
            .buttonStyle(.plain)
            // Primary, as menu items are: secondary gray made the actions read as captions.
            .foregroundStyle(Color.primary)
            .interfaceFont(.callout)
            .padding(.horizontal, metrics.points(10))
            .padding(.vertical, metrics.points(4))
        }
        .frame(width: 340)
        // Keep text legible over every glass backdrop while retaining the glass rim.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        .environment(\.appearsActive, true)
    }

    private var openButton: some View {
        Button { model.showMainWindow() } label: {
            Text("Open Rota").fixedSize().footerTarget()
        }
    }

    private var settingsButton: some View {
        Button { model.showSettings() } label: {
            // Text only, like its neighbors: one icon among three read as a different kind of action.
            Text("Settings\u{2026}").fixedSize().footerTarget()
        }
    }

    private var quitButton: some View {
        Button { NSApp.terminate(nil) } label: { Text("Quit").fixedSize().footerTarget() }
            .help("Quit Rota")
    }
}

private struct MenuRoutineRow: View {
    @Environment(\.interfaceScale) private var metrics
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
        HStack(spacing: metrics.points(8)) {
            HarnessStatusIcon(harness: routine.harness) {
                StatusDot(routine: routine)
            }
            VStack(alignment: .leading, spacing: metrics.points(1)) {
                Text(routine.name).lineLimit(1)
                Text(NextRunFormat.subtitle(routine, running: running))
                    .interfaceFont(.caption)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: toggleRun) {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(running ? "Stop" : "Run now")
            }
        }
        .padding(.horizontal, metrics.points(8))
        .padding(.vertical, metrics.points(5))
        .background(hovering ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: metrics.points(6)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        // Hover shows Run and Stop to a pointer; VoiceOver and Full Keyboard Access get them as actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(routine.name)
        .accessibilityValue(spokenState(running: running))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens its latest session")
        .accessibilityAction(.default, open)
        .accessibilityAction(named: running ? "Stop" : "Run Now", toggleRun)
    }

    /// The subtitle and the dot's state, the state once when the subtitle already says it.
    private func spokenState(running: Bool) -> String {
        let text = NextRunFormat.subtitle(routine, running: running)
        let status = StatusDot.status(of: routine, in: model.scheduler)
        return text.localizedCaseInsensitiveContains(status) ? text : "\(text), \(status)"
    }

}

/// Running, last run failed, last run fine, or off.
struct StatusDot: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let routine: Routine

    var body: some View {
        // One history read for both the colour and the spoken state.
        let last = Self.lastRun(of: routine, in: model.scheduler)
        Circle()
            .fill(color(last))
            .frame(width: metrics.points(8), height: metrics.points(8))
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
    static func subtitle(_ routine: Routine, running: Bool) -> String {
        if running { return "Running on \(routine.harness.title)" }
        guard routine.enabled, let next = routine.nextFire else { return "\(routine.harness.title), paused" }
        return "\(routine.harness.title), next run \(string(next))"
    }

    static func string(_ date: Date, now: Date = .now) -> String {
        if date.timeIntervalSince(now) < 24 * 3600 {
            return date.formatted(.relative(presentation: .numeric))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

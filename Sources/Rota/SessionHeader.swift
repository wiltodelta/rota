import RotaCore
import SwiftUI

/// The session's date, harness and status, Show Routine, and its actions. Its own view, so a
/// measured width change re-runs only the header, not the transcript's session view.
struct SessionHeader: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    /// The record as the scheduler has it now.
    let current: RunRecord
    let routine: Routine
    let running: Bool
    @State private var fit = SessionHeaderFit()

    var body: some View { header }

    private var header: some View {
        let spacing = metrics.points(12)
        let arrangement = fit.arrangement(spacing: spacing)
        return GlassControls(spacing: spacing) {
            // One structure for both arrangements, so the summary keeps its identity when the actions move.
            VStack(alignment: .leading, spacing: metrics.points(8)) {
                HStack(spacing: spacing) {
                    sessionSummary
                    Spacer(minLength: spacing)
                    showRoutine
                    if arrangement.oneRow { sessionActions(iconOnly: false) }
                }
                if !arrangement.oneRow {
                    HStack(spacing: spacing) {
                        Spacer(minLength: 0)
                        sessionActions(iconOnly: arrangement.iconOnly)
                    }
                }
            }
            // Both bounds, so the measured width is the offered one even while the content overflows it;
            // a frame with only a maximum grows with its content and the header never narrows again.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fit.available = $0 }
            .background { headerMeasures }
        }
        .modifier(GlassActionStyle())
    }

    /// Hidden ideal-size copies that `SessionHeaderFit` reads; they keep their identity between passes.
    private var headerMeasures: some View {
        ZStack {
            sessionSummary.fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fit.summary = $0 }
            showRoutine
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fit.routine = $0 }
            sessionActions(iconOnly: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fit.labeledActions = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: metrics.points(2)) {
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .interfaceFont(.callout)
            Text([record.harness.title, record.trigger == .catchUp ? "missed slot, run late" : nil,
                  current.statusTitle].compactMap { $0 }.joined(separator: " \u{00B7} "))
                .interfaceFont(.caption)
                .foregroundStyle(record.outcome.isFailure ? Color.errorText : Color.secondaryText)
            if let id = record.discussedSessionID,
               let source = model.scheduler.records(for: routine.id).first(where: { $0.id == id }) {
                // A discussion leads back to the Shell run it asks about.
                Button { model.selection = .session(source.id) } label: {
                    Label("About the Shell run at " + source.startedAt.formatted(date: .omitted, time: .shortened),
                          systemImage: "arrow.turn.up.left")
                        .interfaceFont(.caption)
                }
                .buttonStyle(.link)
                .help("Open the Shell session this discussion is about")
                .accessibilityIdentifier("discussedSession")
            }
        }
    }

    private var showRoutine: some View {
        Button(interfaceTitle: "Show Routine", systemImage: "calendar") { model.selection = .routine(routine.id) }
            .fixedSize()
            .help("Show \(routine.name)'s schedule, settings, and sessions")
            .accessibilityIdentifier("showSessionRoutine")
    }

    @ViewBuilder
    private func sessionActions(iconOnly: Bool) -> some View {
        if iconOnly {
            HStack(spacing: metrics.points(12)) { actionButtons.labelStyle(.iconOnly) }.fixedSize()
        } else {
            HStack(spacing: metrics.points(12)) { actionButtons }.fixedSize()
        }
    }

    /// Labeled actions first, then the icon-only utilities, with Delete last and apart from Stop.
    @ViewBuilder
    private var actionButtons: some View {
        if current.harness.isAgent {
            SessionRestartMenu(record: current)
        }
        // A session that takes messages has Stop beside its field.
        if running && !model.scheduler.canMessage(record) {
            Button(interfaceTitle: "Stop", systemImage: "stop.fill") { model.scheduler.stop(record.id) }
                .accessibilityIdentifier("stopSession")
        }
        if model.scheduler.terminalCommand(for: record) != nil {
            Button(interfaceTitle: model.terminalTitle(record), systemImage: "terminal") {
                model.openInTerminal(record)
            }
            .help(running ? "Open this session in Terminal" : "Continue this session in Terminal")
            .accessibilityIdentifier("openTerminal")
        }
        if let path = record.logPath {
            Button(interfaceTitle: "Show Log in Finder", systemImage: "folder") {
                model.revealLog(record)
            }
            .labelStyle(.iconOnly)
            .help("Show log in Finder")
        }
        Button(interfaceTitle: "Delete Session…", systemImage: "trash", role: .destructive) {
            model.sessionToDelete = record
        }
        .labelStyle(.iconOnly)
        .help("Delete this session and its logs")
        .disabled(!model.scheduler.canDelete(current))
        .accessibilityIdentifier("deleteSession")
    }
}

/// How the session header lays out its parts, chosen from widths measured once per change.
///
/// `ViewThatFits` rebuilt every candidate on each layout pass, and the detail column runs one per
/// keystroke in the message field, so typing paid for four copies of the action row each time.
/// The same choice applies: one row while the labeled actions fit beside the summary, otherwise the
/// actions on a second row, labeled if they fit there.
struct SessionHeaderFit: Equatable {
    /// The header's own width.
    var available: CGFloat = 0
    /// Ideal widths of the summary, Show Routine and the labeled action row.
    var summary: CGFloat = 0
    var routine: CGFloat = 0
    var labeledActions: CGFloat = 0

    struct Arrangement: Equatable {
        var oneRow: Bool
        var iconOnly: Bool
    }

    /// `spacing` is the row's spacing, which is also each spacer's minimum length.
    func arrangement(spacing: CGFloat) -> Arrangement {
        // Before the first measurement, the widest arrangement; it settles in the same update.
        guard available > 0 else { return Arrangement(oneRow: true, iconOnly: false) }
        // Summary, spacer, Show Routine and actions, with the spacer's minimum and three gaps between.
        // The action row's ideal width was its labeled one, so icons alone never kept it on one row.
        if summary + routine + labeledActions + spacing * 4 <= available {
            return Arrangement(oneRow: true, iconOnly: false)
        }
        // The second row: a flexible spacer, one gap, then the actions.
        return Arrangement(oneRow: false, iconOnly: labeledActions + spacing > available)
    }
}

/// The first candidate whose measured ideal width fits, as `ViewThatFits` chooses, else the one
/// after the measured ones. Hidden copies supply the widths and keep their identity between layout
/// passes, which `ViewThatFits` candidates do not.
struct FirstFit: Equatable {
    var available: CGFloat = 0
    var ideals: [CGFloat] = []

    mutating func set(_ index: Int, _ width: CGFloat) {
        if ideals.count <= index { ideals += Array(repeating: 0, count: index + 1 - ideals.count) }
        ideals[index] = width
    }

    var choice: Int {
        // Before the first measurement, the first candidate; it settles in the same update.
        guard available > 0 else { return 0 }
        return ideals.firstIndex { $0 <= available } ?? ideals.count
    }
}

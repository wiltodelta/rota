import AppKit
import RotaCore
import SwiftUI

struct MainSidebar: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(\.appearsActive) private var appearsActive
    @Environment(AppModel.self) private var model
    @AppStorage("routinesExpanded") private var routinesExpanded = true
    private enum Focus: Hashable { case list, filter }
    @FocusState private var focus: Focus?
    @State private var filterFocusRequested = false

    let records: [RunRecord]

    var body: some View {
        @Bindable var model = model
        let visible = model.sessionFilter.visibleRecords(records, selection: model.selection)
        let activeList = appearsActive && focus == .list
        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                Section(isExpanded: $routinesExpanded) {
                    ForEach(RoutineOrder.byNextRun(model.scheduler.routines)) { routine in
                        RoutineRow(routine: routine,
                                   onAccent: activeList && model.selection == .routine(routine.id))
                            .interfaceFont(.body)
                            .tag(SidebarItem.routine(routine.id))
                    }
                } header: {
                    SidebarHeader(title: "Routines")
                }
                Section {
                    sessionHeader
                        .selectionDisabled()
                        .id("sessionFilterHeader")
                    if model.sessionFilter != .all {
                        SessionFilterToken(filter: model.sessionFilter).selectionDisabled()
                    }
                    if visible.isEmpty {
                        Text("No matching sessions")
                            .interfaceFont(.callout)
                            .foregroundStyle(Color.secondaryText)
                            .selectionDisabled()
                            .accessibilityIdentifier("sessionFilterEmpty")
                    }
                    ForEach(DayGroup.group(visible), id: \.title) { group in
                        Text(group.title)
                            .interfaceFont(.caption)
                            .foregroundStyle(Color.secondaryText)
                            .accessibilityAddTraits(.isHeader)
                            .selectionDisabled()
                        ForEach(group.records) { record in
                            SessionRow(record: record,
                                       onAccent: activeList && model.selection == .session(record.id))
                                .interfaceFont(.body).tag(SidebarItem.session(record.id))
                        }
                    }
                }
            }
            .accessibilityIdentifier("routineSidebar")
            .focused($focus, equals: .list)
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                guard press.modifiers.contains(.shift) || press.key.character == "\u{19}" else { return .ignored }
                proxy.scrollTo("sessionFilterHeader", anchor: .top)
                filterFocusRequested = true
                return .handled
            }
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: metrics.points(8)) {
            SidebarHeader(title: "Sessions")
            Spacer(minLength: 0)
            SessionFilterMenu(filter: model.sessionFilter) { focus = .list }
                .focused($focus, equals: .filter)
                .task(id: filterFocusRequested) {
                    guard filterFocusRequested else { return }
                    focus = .filter
                    filterFocusRequested = false
                }
                .onKeyPress(keys: [.tab]) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    focus = .list
                    return .handled
                }
        }
        .textCase(nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionsSection")
    }
}

/// A routine in the sidebar: its name, and its agent with the next run.
private struct RoutineRow: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let routine: Routine
    /// Selected in the focused list; passed in, so only the rows whose value flips redraw.
    let onAccent: Bool

    var body: some View {
        HStack(spacing: metrics.points(SidebarIconColumn.gap)) {
            HarnessStatusIcon(harness: routine.harness, foreground: SidebarText.primary(onAccent: onAccent)) {
                StatusDot(routine: routine)
            }
            VStack(alignment: .leading, spacing: metrics.points(1)) {
                // Explicit, so an inactive window does not dim the name below its caption.
                Text(routine.name).interfaceFont(.body)
                    .lineLimit(1).foregroundStyle(SidebarText.primary(onAccent: onAccent))
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(NextRunFormat.subtitle(routine, running: model.scheduler.hasActiveSession(routine.id)))
                        .interfaceFont(.caption)
                        .foregroundStyle(SidebarText.caption(onAccent: onAccent))
                        .lineLimit(2)
                        .accessibilityIdentifier("routineHarness-" + routine.id)
                }
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    /// Selected in the focused list, as for `RoutineRow`.
    let onAccent: Bool
    @State private var snapshot: TranscriptSnapshot?
    @State private var reader = TranscriptSessionReader()

    var body: some View {
        HStack(spacing: metrics.points(SidebarIconColumn.gap)) {
            HarnessStatusIcon(harness: record.harness, foreground: SidebarText.primary(onAccent: onAccent)) {
                Group {
                    if record.outcome == .running, record.terminalState != .waiting {
                        RunActivityIndicator()
                    } else {
                        Circle()
                            .fill(color)
                            .frame(width: metrics.points(8), height: metrics.points(8))
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(record.statusTitle)
            }
            VStack(alignment: .leading, spacing: metrics.points(1)) {
                Text(verbatim: SessionPreview.text(for: record, snapshot: snapshot))
                    .interfaceFont(.body)
                    .fontWeight(record.isUnread ? .semibold : .regular)
                    // Explicit, so an inactive window does not dim the preview below its captions.
                    .foregroundStyle(SidebarText.primary(onAccent: onAccent))
                    .lineLimit(2)
                    .accessibilityIdentifier("sidebarPreview-" + record.id.uuidString)
                Text(model.scheduler.routine(record.routineID)?.name ?? record.routineID)
                    .interfaceFont(.caption)
                    .foregroundStyle(SidebarText.caption(onAccent: onAccent))
                    .lineLimit(1)
                Text(details)
                    .interfaceFont(.caption)
                    .foregroundStyle(SidebarText.caption(onAccent: onAccent))
                    .lineLimit(1)
                    .accessibilityIdentifier("sessionHarness-" + record.id.uuidString)
            }
            Spacer(minLength: 0)
            if record.attention != nil {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(onAccent ? SidebarText.primary(onAccent: true) : Color.orange)
                    .help(model.scheduler.canMessage(record) ? "Needs your reply" : "Needs your attention")
                    .accessibilityLabel(model.scheduler.canMessage(record)
                        ? "Needs your reply" : "Needs your attention")
            } else if record.isUnread {
                dot(.accentColor, size: 7)
                    .accessibilityLabel("Unread")
            }
        }
        .task(id: record) {
            guard let path = record.logPath else { return }
            repeat {
                let next = await reader.read(log: URL(fileURLWithPath: path), shell: record.harness == .shell,
                                             finished: record.outcome != .running)
                guard !Task.isCancelled else { return }
                if snapshot != next { snapshot = next }
                if record.outcome != .running { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled
        }
        .contextMenu {
            Button("Delete Session…", role: .destructive) { model.sessionToDelete = record }
                .disabled(!model.scheduler.canDelete(record))
        }
    }

    private func dot(_ fill: Color, size: CGFloat) -> some View {
        Circle()
            .fill(fill)
            // The selected row's accent fill hides a blue or green dot.
            .overlay {
                if onAccent { Circle().strokeBorder(SidebarText.primary(onAccent: true), lineWidth: 1.5) }
            }
            .frame(width: metrics.points(size), height: metrics.points(size))
    }

    private var details: String {
        var parts = [record.harness.title, record.startedAt.formatted(date: .omitted, time: .shortened),
                     record.statusTitle]
        if record.trigger == .catchUp { parts.insert("catch-up", at: 1) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var color: Color {
        if record.outcome == .running { return .blue }
        if record.awaitsReply { return .orange }
        if record.outcome == .cancelled { return Color.secondary }
        return record.outcome.isFailure ? .red : .green
    }
}

extension AppModel {
    func showMainWindow(selecting item: SidebarItem? = nil) {
        if let item { selection = item }
        openMainWindow()
    }

    func selectSessionFilter(_ filter: SessionFilter) {
        sessionFilter = filter
        selection = filter.destination(from: selection, records: scheduler.allRecords())
    }
    /// A routine's latest session, or the routine itself before its first run.
    func latest(of routineID: String) -> SidebarItem {
        SidebarItem.latest(routineID: routineID, records: scheduler.records(for: routineID))
    }

}

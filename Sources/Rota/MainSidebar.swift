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
    @State private var routineToDelete: Routine?
    /// Where the native Routines header and the session rows' content start. Sessions and
    /// the day titles are list rows, whose inset the system sets wider than a header's.
    @State private var headerEdge: CGFloat?
    @State private var rowEdge: CGFloat?

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
                        .leadingEdge($headerEdge)
                }
                Section {
                    sessionHeader
                        .selectionDisabled()
                        .id("sessionFilterHeader")
                    if !model.sessionFilter.selected.isEmpty {
                        SessionFilterFlow(spacing: metrics.points(8)) {
                            ForEach(model.sessionFilter.selected) { filter in
                                SessionFilterToken(filter: filter)
                            }
                        }
                        .selectionDisabled()
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
                            .padding(.leading, headingShift)
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
            .background(SidebarSelectionScroller(selection: model.selection, suppress: focus == .filter))
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                // Shift-Tab from the filter bubbles up here too; it continues to the previous control.
                guard focus == .list, press.modifiers.contains(.shift) || press.key.character == "\u{19}" else {
                    return .ignored
                }
                proxy.scrollTo("sessionFilterHeader", anchor: .top)
                filterFocusRequested = true
                return .handled
            }
            // As in Mail: Return goes to the message, Space and Page keys read it, Delete removes it.
            .onKeyPress(.return) {
                guard focus == .list, case .session = model.selection else { return .ignored }
                model.keyboard.focusComposer()
                return .handled
            }
            .onKeyPress(keys: [.space, .pageUp, .pageDown]) { press in
                guard focus == .list, case .session = model.selection else { return .ignored }
                model.keyboard.scrollTranscript(down: press.key == .pageDown
                                                    || (press.key == .space && !press.modifiers.contains(.shift)))
                return .handled
            }
            .onDeleteCommand {
                guard focus == .list else { return }
                switch model.selection {
                case .session(let id):
                    if let record = model.scheduler.current(id), model.scheduler.canDelete(record) {
                        model.sessionToDelete = record
                    }
                case .routine(let id): routineToDelete = model.scheduler.routine(id)
                case .calendar, nil: break
                }
            }
            .onChange(of: model.keyboard.listFocus) { focus = .list }
            .routineDeleteConfirmation($routineToDelete) {}
        }
    }

    /// Moves a heading in a list row onto the Routines header's edge, whatever insets
    /// this macOS version and interface scale give each.
    private var headingShift: CGFloat {
        guard let headerEdge, let rowEdge else { return 0 }
        return headerEdge - rowEdge
    }

    private var sessionHeader: some View {
        HStack(spacing: metrics.points(8)) {
            SidebarHeader(title: "Sessions").padding(.leading, headingShift)
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
        .leadingEdge($rowEdge)
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
                SessionPreviewText(record: record)
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
        .contextMenu {
            ReadMarkButton(model: model, record: record)
            Divider()
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
        var parts = [record.harness.title, record.lastActivityAt.formatted(date: .omitted, time: .shortened),
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

extension View {
    /// Asks before deleting a routine with its sessions, from the sidebar or its edit sheet.
    func routineDeleteConfirmation(_ routine: Binding<Routine?>, deleted: @escaping () -> Void) -> some View {
        modifier(RoutineDeleteConfirmation(routine: routine, deleted: deleted))
    }
}

private struct RoutineDeleteConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var routine: Routine?
    let deleted: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete \(routine?.name ?? "Routine")?", isPresented: Binding(
            get: { routine != nil }, set: { if !$0 { routine = nil } }
        ), presenting: routine) { routine in
            Button("Delete", role: .destructive) {
                guard model.scheduler.delete(routine.id) else { return }
                model.selection = nil
                deleted()
            }
            .accessibilityIdentifier("confirmDeleteRoutine")
        } message: { _ in
            Text("Its sessions and logs are deleted too. The project skill is not touched.")
        }
    }
}

extension AppModel {
    func showMainWindow(selecting item: SidebarItem? = nil) {
        if let item { selection = item }
        openMainWindow()
    }

    func selectSessionFilter(_ filter: SessionFilter) {
        sessionFilter = SessionFilters(filter)
        selection = sessionFilter.destination(from: selection, records: scheduler.allRecords())
    }
    func toggleSessionFilter(_ filter: SessionFilter) {
        sessionFilter = sessionFilter.toggling(filter)
        selection = sessionFilter.destination(from: selection, records: scheduler.allRecords())
    }

    /// A routine's latest session, or the routine itself before its first run.
    func latest(of routineID: String) -> SidebarItem {
        SidebarItem.latest(routineID: routineID, records: scheduler.records(for: routineID))
    }
}

/// NSTableView scrolls an unmeasured row by its estimated height first; observing its selection
/// notifications keeps tall rows and programmatic jumps (`Show Routine`) inside the visible viewport.
private struct SidebarSelectionScroller: NSViewRepresentable {
    let selection: SidebarItem?
    let suppress: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.suppress = suppress
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.suppress = suppress
        view.attachIfNeeded()
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.detach()
    }

    final class ProbeView: NSView {
        var suppress = false
        private var ready = false
        private weak var outline: NSTableView?

        deinit { NotificationCenter.default.removeObserver(self) }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.attachIfNeeded()
                self?.ready = true
            }
        }

        func attachIfNeeded() {
            guard window != nil else { return }
            if let current = outline, current.window === window { return }
            detach()
            guard let found = Self.findOutline(from: self) else { return }
            outline = found
            NotificationCenter.default.addObserver(
                self, selector: #selector(outlineSelectionChanged),
                name: NSOutlineView.selectionDidChangeNotification, object: found
            )
        }

        func detach() {
            NotificationCenter.default.removeObserver(
                self, name: NSOutlineView.selectionDidChangeNotification, object: nil
            )
            outline = nil
        }

        @objc private func outlineSelectionChanged(_ notification: Notification) {
            scheduleReveal()
        }

        private func scheduleReveal() {
            guard ready, !suppress else { return }
            DispatchQueue.main.async { [weak self] in self?.revealSelectedRow() }
        }

        private func revealSelectedRow() {
            guard !suppress, let window, let outline else { return }
            window.layoutIfNeeded()
            let row = outline.selectedRow
            guard row >= 0 else { return }
            outline.rowView(atRow: row, makeIfNecessary: true)?.layoutSubtreeIfNeeded()
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            outline.layoutSubtreeIfNeeded()
            outline.scrollRowToVisible(row)
            guard let scroll = outline.enclosingScrollView else { return }
            let rowRect = outline.rect(ofRow: row)
            let visible = scroll.documentVisibleRect
            if rowRect.maxY > visible.maxY {
                scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: rowRect.maxY - visible.height))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if rowRect.minY < visible.minY {
                scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: rowRect.minY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private static func findOutline(from probe: NSView) -> NSTableView? {
            var scope: NSView = probe
            while let parent = scope.superview, !(parent is NSSplitView) {
                scope = parent
            }
            return searchOutline(in: scope)
        }

        private static func searchOutline(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView,
               table.accessibilityIdentifier() == "routineSidebar" || table is NSOutlineView {
                return table
            }
            for subview in view.subviews {
                if let found = searchOutline(in: subview) { return found }
            }
            return nil
        }
    }
}

private extension View {
    /// Reports where this view starts, so two rows of one list can share an edge.
    func leadingEdge(_ edge: Binding<CGFloat?>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { edge.wrappedValue = $0 }
    }
}

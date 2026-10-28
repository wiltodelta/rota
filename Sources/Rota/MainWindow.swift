import AppKit
import RotaCore
import SwiftUI

/// What the sidebar selects: a session, the main thing, or a routine.
enum SidebarItem: Hashable {
    case session(UUID)
    case routine(String)

    static func latest(routineID: String, records: [RunRecord]) -> SidebarItem {
        records.filter { !$0.isSkip }.max { $0.startedAt < $1.startedAt }
            .map { .session($0.id) } ?? .routine(routineID)
    }
}

/// Routines stay above the growing session history, which is grouped by day
/// with the newest sessions first.
struct MainWindow: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    @State private var sidebarWidth: CGFloat = 280
    // Seed the ideal once; later measurements save the next launch's preference.
    @State private var restoredSidebarWidth = UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 280

    private var records: [RunRecord] {
        _ = model.scheduler.historyVersion
        return model.scheduler.allRecords()
    }

    private func title(_ records: [RunRecord]) -> String {
        if let pane = model.settingsPane { return pane.title }
        return switch model.selection {
        case .routine(let id): model.scheduler.routine(id)?.name ?? "Rota"
        case .session(let id):
            records.first(where: { $0.id == id }).flatMap { model.scheduler.routine($0.routineID)?.name } ?? "Rota"
        case nil: "Rota"
        }
    }

    var body: some View {
        @Bindable var model = model
        let records = records
        let title = title(records)
        // Dragging the divider shut hides the list too, and the binding keeps that.
        NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarShown ? .all : .detailOnly },
            set: { if model.settingsPane == nil { model.sidebarVisible = $0 != .detailOnly } }
        )) {
            Group {
                if model.settingsPane != nil {
                    SettingsSidebar()
                } else {
                    MainSidebar(records: records)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                sidebarWidth = width
                if model.sidebarShown, width >= min(metrics.points(240), 280) {
                    UserDefaults.standard.set(Double(width), forKey: "sidebarWidth")
                }
            }
            // Restore the last visible width in points; scaling the ideal makes it drift on zoom changes.
            .navigationSplitViewColumnWidth(min: min(metrics.points(240), 280), ideal: CGFloat(restoredSidebarWidth),
                                            max: metrics.points(360))
            .overlay {
                // The detail explains a first routine and offers both ways to add one.
                if model.scheduler.routines.isEmpty, model.settingsPane == nil {
                    Text("No routines yet")
                        .interfaceFont(.body)
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityIdentifier("sidebarEmpty")
                }
            }
        } detail: {
            detail(records)
        }
        .background(WindowToolbarOverlay(
            content: AnyView(MainWindowToolbar(title: title, sidebarWidth: model.sidebarShown ? sidebarWidth : 0,
                                              toggleSidebar: { model.sidebarVisible.toggle() },
                                              importRoutines: { model.presentingImport = true },
                                              newRoutine: { model.presentingNew = true },
                                              showsActions: model.settingsPane == nil)
                .interfaceScale(model.interfaceScale)),
            height: max(52, metrics.points(52)), title: title
        ).frame(width: 0, height: 0))
        .sheet(isPresented: $model.presentingImport) { ImportSheet() }
        .sheet(isPresented: $model.presentingNew) { NewRoutineSheet() }
        .confirmationDialog("Delete Session?", isPresented: Binding(
            get: { model.sessionToDelete != nil },
            set: { if !$0 { model.sessionToDelete = nil } }
        ), titleVisibility: .visible, presenting: model.sessionToDelete) { record in
            Button("Delete Session", role: .destructive) {
                model.deleteSession(record)
                model.sessionToDelete = nil
            }
            .accessibilityIdentifier("confirmDeleteSession")
        } message: { record in
            let date = record.startedAt.formatted(date: .abbreviated, time: .shortened)
            Text("Permanently delete the session from \(date) and its logs? "
                 + "The routine and the agent's own history stay unchanged.")
        }
        .alert("Rota", isPresented: Binding(
            get: { model.scheduler.lastError != nil },
            set: { if !$0 { model.scheduler.lastError = nil } }
        )) {
            Button("OK") { model.scheduler.lastError = nil }
        } message: {
            Text(model.scheduler.lastError ?? "")
        }
        .onAppear {
            if model.selection == nil, model.settingsPane == nil {
                model.selection = records.first.map { .session($0.id) }
            }
        }
        // Picking a routine or session leaves Settings.
        .onChange(of: model.selection) { _, item in if item != nil { model.closeSettings() } }
    }

    @ViewBuilder
    private func detail(_ records: [RunRecord]) -> some View {
        if let pane = model.settingsPane {
            SettingsDetail(pane: pane)
        } else {
            sessionDetail(records)
        }
    }

    @ViewBuilder
    private func sessionDetail(_ records: [RunRecord]) -> some View {
        switch model.selection {
        case .session(let id):
            if let record = records.first(where: { $0.id == id }),
               let routine = model.scheduler.routine(record.routineID) {
                SessionView(record: record, routine: routine).id(record.id)
            } else {
                placeholder
            }
        case .routine(let id):
            if let routine = model.scheduler.routine(id) {
                RoutineDetail(routine: routine).id(routine.id)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    /// What the detail says when nothing is selected: how to get a first session.
    private var placeholder: some View {
        Group {
            if model.scheduler.routines.isEmpty {
                ContentUnavailableView {
                    Label("No routines yet", systemImage: "calendar.badge.clock").interfaceFont(.title2)
                } description: {
                    Text("A routine runs a prompt or a command on a schedule. "
                         + "Each run becomes a session here.")
                        .interfaceFont(.body)
                        .foregroundStyle(Color.secondaryText)
                } actions: {
                    HStack(spacing: metrics.points(12)) {
                        Button(interfaceTitle: "Import Routines\u{2026}") { model.presentingImport = true }
                            .accessibilityIdentifier("emptyImport")
                        Button(interfaceTitle: "New Routine\u{2026}") { model.presentingNew = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("emptyNewRoutine")
                    }
                }
            } else if model.scheduler.allRecords().isEmpty {
                ContentUnavailableView {
                    Label("No sessions yet", systemImage: "bubble.left.and.text.bubble.right").interfaceFont(.title2)
                } description: {
                    Text("Routines start a session when they run. Pick a routine and choose Run Now.")
                        .interfaceFont(.body)
                        .foregroundStyle(Color.secondaryText)
                }
            } else {
                Text("Select a session").foregroundStyle(Color.secondaryText)
            }
        }
    }
}

private struct MainSidebar: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(\.appearsActive) private var appearsActive
    @Environment(AppModel.self) private var model
    @AppStorage("routinesExpanded") private var routinesExpanded = true
    @FocusState private var sidebarFocused: Bool

    let records: [RunRecord]

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section(isExpanded: $routinesExpanded) {
                ForEach(RoutineOrder.byNextRun(model.scheduler.routines)) { routine in
                    RoutineRow(routine: routine,
                               onAccent: appearsActive && sidebarFocused && model.selection == .routine(routine.id))
                        .interfaceFont(.body)
                        .tag(SidebarItem.routine(routine.id))
                }
            } header: {
                SidebarHeader(title: "Routines")
            }
            Section {
                ForEach(DayGroup.group(records), id: \.title) { group in
                    Text(group.title)
                        .interfaceFont(.caption)
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                        .selectionDisabled()
                    ForEach(group.records) { record in
                        SessionRow(record: record,
                                   onAccent: appearsActive && sidebarFocused && model.selection == .session(record.id))
                            .interfaceFont(.body).tag(SidebarItem.session(record.id))
                    }
                }
            } header: {
                SidebarHeader(title: "Sessions")
                    .accessibilityIdentifier("sessionsSection")
            }
        }
        .accessibilityIdentifier("routineSidebar")
        .focused($sidebarFocused)
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
                    Text(NextRunFormat.subtitle(routine, running: model.scheduler.active[routine.id] != nil))
                        .interfaceFont(.caption)
                        .foregroundStyle(SidebarText.caption(onAccent: onAccent))
                        .lineLimit(2)
                        .accessibilityIdentifier("routineHarness-" + routine.id)
                }
            }
        }
    }
}

/// A sidebar row's leading column, a harness mark or a Settings icon, and its gap
/// to the name: shared, so every name in both sidebars starts on one edge.
enum SidebarIconColumn {
    static let width: CGFloat = 24
    static let gap: CGFloat = 8
}

/// A sidebar section title, shared by the main and Settings sidebars.
struct SidebarHeader: View {
    let title: String

    var body: some View {
        Text(title).interfaceFont(.caption).fontWeight(.semibold).foregroundStyle(Color.secondaryText)
    }
}

/// Selected labels choose a contrasting foreground without replacing native
/// selection. macOS 27 sidebars use the control accent rather than AppKit's
/// darker selected-content color. Both appearances and all accents are captured.
enum SidebarText {
    private static let selected = Color(nsColor: NSColor(name: nil) { appearance in
        var color = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            if #available(macOS 27, *) {
                background = .controlAccentColor
            } else {
                background = .selectedContentBackgroundColor
            }
            color = foreground(on: background)
        }
        return color
    })

    static func primary(onAccent: Bool) -> Color {
        onAccent ? selected : Color.primary
    }

    static func caption(onAccent: Bool) -> Color {
        onAccent ? selected : Color.secondaryText
    }

    static func foreground(on background: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.sRGB) else { return .labelColor }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        // Choose whichever gives the greater WCAG contrast ratio. At this
        // crossover both black and white exceed 4.5:1 against an opaque fill.
        return luminance > sqrt(0.05 * 1.05) - 0.05 ? .black : .white
    }
}

/// Sessions grouped the way a chat app does: Today, Yesterday, then by date.
struct DayGroup {
    let title: String
    var records: [RunRecord]

    static func group(_ records: [RunRecord], calendar: Calendar = .current, now: Date = .now) -> [DayGroup] {
        var groups: [DayGroup] = []
        for record in records {
            let title: String
            if calendar.isDate(record.startedAt, inSameDayAs: now) {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(record.startedAt, inSameDayAs: yesterday) {
                title = "Yesterday"
            } else {
                title = record.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }
            if groups.last?.title == title {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append(DayGroup(title: title, records: [record]))
            }
        }
        return groups
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

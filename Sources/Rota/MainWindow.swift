import AppKit
import RotaCore
import SwiftUI

/// What the sidebar selects: a session, the main thing, or a routine.
enum SidebarItem: Hashable {
    case session(UUID)
    case routine(String)

    static func latest(routineID: String, records: [RunRecord]) -> SidebarItem {
        records.filter { !$0.isSkip }.max { $1.isMoreRecentlyActive(than: $0) }
            .map { .session($0.id) } ?? .routine(routineID)
    }
}

/// Routines stay above the growing session history, which is grouped by day
/// with the most recently active sessions first.
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
                    VStack(spacing: 0) {
                        MainSidebar(records: records)
                        SidebarSettingsButton()
                    }
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
            } else if model.sessionFilter != .all,
                      !model.scheduler.allRecords().contains(where: { model.sessionFilter.includes($0) }) {
                ContentUnavailableView {
                    Label("No matching sessions", systemImage: "line.3.horizontal.decrease")
                        .interfaceFont(.title2)
                } description: {
                    Text("Try another session filter.").interfaceFont(.body).foregroundStyle(Color.secondaryText)
                } actions: {
                    Button(interfaceTitle: "Show All Sessions") { model.selectSessionFilter(.all) }
                        .accessibilityIdentifier("resetSessionFilter")
                }
            } else {
                Text("Select a session").foregroundStyle(Color.secondaryText)
            }
        }
    }
}

/// A sidebar row's leading column, a harness mark or a Settings icon, and its gap
/// to the name: shared, so every name in both sidebars starts on one edge.
enum SidebarIconColumn {
    static let width: CGFloat = 24
    static let gap: CGFloat = 8
    /// The sidebar list's own leading row inset, which does not follow zoom.
    static let listInset: CGFloat = 16
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
            if calendar.isDate(record.lastActivityAt, inSameDayAs: now) {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(record.lastActivityAt, inSameDayAs: yesterday) {
                title = "Yesterday"
            } else {
                title = record.lastActivityAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
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

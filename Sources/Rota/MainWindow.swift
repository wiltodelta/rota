import RotaCore
import SwiftUI

/// What the sidebar selects: a session, the main thing, or a routine.
enum SidebarItem: Hashable {
    case session(UUID)
    case routine(String)
}

/// Routines stay above the growing session history, which is grouped by day
/// with the newest sessions first.
struct MainWindow: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    @State private var sidebarWidth: CGFloat = 280

    private var records: [RunRecord] {
        _ = model.scheduler.historyVersion
        return model.scheduler.allRecords()
    }

    private func title(_ records: [RunRecord]) -> String {
        switch model.selection {
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
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly }
        )) {
            List(selection: $model.selection) {
                Section {
                    ForEach(model.scheduler.routines) { routine in
                        HStack(spacing: metrics.points(8)) {
                            StatusDot(routine: routine)
                            VStack(alignment: .leading, spacing: metrics.points(1)) {
                                Text(routine.name).lineLimit(1)
                                TimelineView(.periodic(from: .now, by: 30)) { _ in
                                    Text(NextRunFormat.subtitle(routine,
                                        running: model.scheduler.active[routine.id] != nil))
                                        .interfaceFont(.caption)
                                        .foregroundStyle(model.selection == .routine(routine.id)
                                            ? Color.primary : Color.secondaryText)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .interfaceFont(.body)
                        .tag(SidebarItem.routine(routine.id))
                    }
                } header: {
                    Text("Routines").interfaceFont(.caption).fontWeight(.semibold)
                }
                ForEach(DayGroup.group(records), id: \.title) { group in
                    Section {
                        ForEach(group.records) { record in
                            SessionRow(record: record).interfaceFont(.body).tag(SidebarItem.session(record.id))
                        }
                    } header: {
                        Text(group.title).interfaceFont(.caption).fontWeight(.semibold)
                    }
                }
            }
            .accessibilityIdentifier("routineSidebar")
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
            .navigationSplitViewColumnWidth(min: min(metrics.points(240), 280),
                                            ideal: min(metrics.points(280), 360),
                                            max: metrics.points(360))
            .overlay {
                if model.scheduler.routines.isEmpty {
                    ContentUnavailableView {
                        Label("No routines", systemImage: "calendar.badge.clock").interfaceFont(.title2)
                    } description: {
                        Text("Import the routines Claude Desktop or Codex schedules, or add one.")
                            .interfaceFont(.body)
                    } actions: {
                        Button(interfaceTitle: "Import Routines") { model.presentingImport = true }
                    }
                }
            }
        } detail: {
            detail(records)
        }
        .background(WindowToolbarOverlay(
            content: AnyView(MainWindowToolbar(title: title, sidebarWidth: model.sidebarVisible ? sidebarWidth : 0,
                                              toggleSidebar: { model.sidebarVisible.toggle() },
                                              importRoutines: { model.presentingImport = true },
                                              newRoutine: { model.presentingNew = true })
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
            if model.selection == nil { model.selection = records.first.map { .session($0.id) } }
        }
    }

    @ViewBuilder
    private func detail(_ records: [RunRecord]) -> some View {
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
                    Label("No sessions yet", systemImage: "bubble.left.and.text.bubble.right").interfaceFont(.title2)
                } description: {
                    Text("Add a routine with + or import one from Claude Desktop or Codex. "
                         + "Each run becomes a session here.")
                        .interfaceFont(.body)
                }
            } else if model.scheduler.allRecords().isEmpty {
                ContentUnavailableView {
                    Label("No sessions yet", systemImage: "bubble.left.and.text.bubble.right").interfaceFont(.title2)
                } description: {
                    Text("Routines start a session when they run. Pick a routine and choose Run Now.")
                        .interfaceFont(.body)
                }
            } else {
                Text("Select a session").foregroundStyle(Color.secondaryText)
            }
        }
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

    var body: some View {
        HStack(spacing: metrics.points(8)) {
            Group {
                if record.outcome == .running, record.terminalState != .waiting {
                    // A working session spins, as in super.engineering's list.
                    ProgressView().controlSize(.mini).frame(width: metrics.points(8), height: metrics.points(8))
                } else {
                    dot(color, size: 8)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(record.statusTitle)
            VStack(alignment: .leading, spacing: metrics.points(1)) {
                Text(model.scheduler.routine(record.routineID)?.name ?? record.routineID)
                    .fontWeight(record.isUnread ? .semibold : .regular)
                    .lineLimit(1)
                Text(details)
                    .interfaceFont(.caption)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if record.attention != nil {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                    .help(model.scheduler.canMessage(record) ? "Needs your reply" : "Needs your attention")
                    .accessibilityLabel(model.scheduler.canMessage(record)
                        ? "Needs your reply" : "Needs your attention")
            } else if record.isUnread {
                dot(.accentColor, size: 7)
                    .accessibilityLabel("Unread")
            }
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
            .overlay { if model.selection == .session(record.id) { Circle().strokeBorder(.white, lineWidth: 1.5) } }
            .frame(width: metrics.points(size), height: metrics.points(size))
    }

    private var details: String {
        var parts = [record.startedAt.formatted(date: .omitted, time: .shortened), record.harness.title,
                     record.statusTitle]
        if record.trigger == .catchUp { parts.insert("catch-up", at: 1) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var color: Color {
        if record.outcome == .running { return .blue }
        if record.outcome == .cancelled { return Color.secondary }
        return record.outcome.isFailure ? .red : .green
    }
}

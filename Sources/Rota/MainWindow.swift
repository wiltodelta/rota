import RotaCore
import SwiftUI

/// What the sidebar selects: a session, the main thing, or a routine.
enum SidebarItem: Hashable {
    case session(UUID)
    case routine(String)
}

/// Sessions first, newest on top, grouped by day, as in Claude Desktop; routines,
/// which change rarely, below them.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    private var records: [RunRecord] {
        _ = model.scheduler.historyVersion
        return model.scheduler.allRecords()
    }

    var body: some View {
        @Bindable var model = model
        let records = records
        // Dragging the divider shut hides the list too, and the binding keeps that.
        NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly }
        )) {
            List(selection: $model.selection) {
                ForEach(DayGroup.group(records), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.records) { record in
                            SessionRow(record: record).tag(SidebarItem.session(record.id))
                        }
                    }
                }
                Section("Routines") {
                    ForEach(model.scheduler.routines) { routine in
                        HStack(spacing: 8) {
                            StatusDot(routine: routine)
                            Text(routine.name).lineLimit(1)
                        }
                        .tag(SidebarItem.routine(routine.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .overlay {
                if model.scheduler.routines.isEmpty {
                    ContentUnavailableView {
                        Label("No routines", systemImage: "calendar.badge.clock")
                    } description: {
                        Text("Import the routines Claude Desktop or Codex schedules, or add one.")
                    } actions: {
                        Button("Import Routines") { model.presentingImport = true }
                    }
                }
            }
        } detail: {
            detail(records)
        }
        .navigationTitle("Rota")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.sidebarVisible.toggle() } label: {
                    Label(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .help("\(model.sidebarVisible ? "Hide" : "Show") the sidebar (Control-Command-S)")
                .accessibilityIdentifier("toggleSidebar")
            }
            ToolbarItemGroup {
                Button { model.presentingImport = true } label: {
                    Label("Import Routines", systemImage: "square.and.arrow.down")
                }
                .help("Import routines from Claude Desktop or Codex")
                .accessibilityIdentifier("import")
                Button { model.presentingNew = true } label: {
                    Label("New Routine", systemImage: "plus")
                }
                .help("New Routine")
                .accessibilityIdentifier("newRoutine")
            }
        }
        .sheet(isPresented: $model.presentingImport) { ImportSheet() }
        .sheet(isPresented: $model.presentingNew) { NewRoutineSheet() }
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
                    Label("No sessions yet", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Add a routine with + or import one from Claude Desktop or Codex. "
                         + "Each run becomes a session here.")
                }
            } else if model.scheduler.allRecords().isEmpty {
                ContentUnavailableView {
                    Label("No sessions yet", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Routines start a session when they run. Pick a routine and choose Run Now.")
                }
            } else {
                Text("Select a session").foregroundStyle(Color.secondaryText)
            }
        }
        .navigationTitle("Rota")
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
    @Environment(AppModel.self) private var model
    let record: RunRecord

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if record.outcome == .running {
                    // A working session spins, as in super.engineering's list.
                    ProgressView().controlSize(.mini).frame(width: 8, height: 8)
                } else {
                    dot(color, size: 8)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(record.outcome.title)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.scheduler.routine(record.routineID)?.name ?? record.routineID)
                    .fontWeight(record.isUnread ? .semibold : .regular)
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if record.attention != nil {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                    .help("Needs your reply")
                    .accessibilityLabel("Needs your reply")
            } else if record.isUnread {
                dot(.accentColor, size: 7)
                    .accessibilityLabel("Unread")
            }
        }
    }

    private func dot(_ fill: Color, size: CGFloat) -> some View {
        Circle()
            .fill(fill)
            // The selected row's accent fill hides a blue or green dot.
            .overlay { if model.selection == .session(record.id) { Circle().strokeBorder(.white, lineWidth: 1.5) } }
            .frame(width: size, height: size)
    }

    private var details: String {
        var parts = [record.startedAt.formatted(date: .omitted, time: .shortened), record.harness.title,
                     record.outcome.title]
        if record.trigger == .catchUp { parts.insert("catch-up", at: 1) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var color: Color {
        if record.outcome == .running { return .blue }
        return record.outcome.isFailure ? .red : .green
    }
}

import Foundation
import RotaCore

/// Session filters use the same persisted states for every harness.
enum SessionFilter: String, CaseIterable, Identifiable {
    case all, running, needsAttention, unread, failed, completed

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All Sessions"
        case .running: return "Running"
        case .needsAttention: return "Needs Attention"
        case .unread: return "Unread"
        case .failed: return "Failed"
        case .completed: return "Completed"
        }
    }

    func includes(_ record: RunRecord) -> Bool {
        guard !record.isSkip else { return false }
        let needsAttention = record.attention != nil || record.questions?.isEmpty == false
            || (record.outcome == .running && record.terminalState == .waiting)
        switch self {
        case .all: return true
        case .running: return record.outcome == .running
        case .needsAttention: return needsAttention
        case .unread: return record.isUnread
        case .failed: return record.outcome.isFailure
        case .completed: return record.outcome == .succeeded && !needsAttention
        }
    }

    func moved(by offset: Int) -> Self {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return Self.allCases[min(max(index + offset, 0), Self.allCases.count - 1)]
    }
}

/// An empty selection means all sessions; selected categories combine with OR.
struct SessionFilters: Equatable {
    static let all = SessionFilters()
    private var categories: Set<SessionFilter> = []

    init() {}

    init(_ filter: SessionFilter) {
        if filter != .all { categories.insert(filter) }
    }

    var selected: [SessionFilter] { SessionFilter.allCases.filter { categories.contains($0) } }
    var title: String { selected.isEmpty ? SessionFilter.all.title : selected.map(\.title).joined(separator: ", ") }

    func contains(_ filter: SessionFilter) -> Bool {
        filter == .all ? categories.isEmpty : categories.contains(filter)
    }

    func toggling(_ filter: SessionFilter) -> Self {
        guard filter != .all else { return .all }
        var next = self
        if !next.categories.insert(filter).inserted { next.categories.remove(filter) }
        return next
    }

    func includes(_ record: RunRecord) -> Bool {
        !record.isSkip && (categories.isEmpty || categories.contains { $0.includes(record) })
    }

    /// Arrow keys retain single-category navigation; the menu combines categories.
    func moved(by offset: Int) -> SessionFilter {
        (selected.last ?? .all).moved(by: offset)
    }

    /// Reading or finishing an open session must not remove the reader's selection.
    func visibleRecords(_ records: [RunRecord], selection: SidebarItem?) -> [RunRecord] {
        records.filter { !$0.isSkip && (includes($0) || selection == .session($0.id)) }
    }

    /// An explicit filter change opens a matching session, or clears an empty result.
    func destination(from selection: SidebarItem?, records: [RunRecord]) -> SidebarItem? {
        let matching = records.lazy.filter { includes($0) }
        if case .session(let id) = selection, matching.contains(where: { $0.id == id }) { return selection }
        return matching.first.map { .session($0.id) }
    }
}

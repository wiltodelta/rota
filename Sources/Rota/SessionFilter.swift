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

    func moved(by offset: Int) -> Self {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return Self.allCases[min(max(index + offset, 0), Self.allCases.count - 1)]
    }
}

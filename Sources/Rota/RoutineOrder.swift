import RotaCore

/// Shared display order for the sidebar and menu bar panel.
enum RoutineOrder {
    static func byNextRun(_ routines: [Routine]) -> [Routine] {
        routines.sorted { lhs, rhs in
            let left = lhs.enabled ? lhs.nextFire : nil
            let right = rhs.enabled ? rhs.nextFire : nil
            switch (left, right) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            default: return false
            }
        }
    }
}

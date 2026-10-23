import RotaCore

/// The harness, and the model when the routine picked one, by the title its CLI lists.
enum ModelLabel {
    static func name(record: RunRecord, models: [Harness: [ModelOption]]) -> String {
        guard let id = record.reportedModel ?? record.model else { return record.harness.title }
        let title = title(id, harness: record.harness, models: models)
        return "\(record.harness.title)  \(title)"
    }

    static func model(record: RunRecord, models: [Harness: [ModelOption]], fallback: String? = nil) -> String {
        guard let id = record.reportedModel ?? fallback ?? record.model else { return "Default model" }
        return title(id, harness: record.harness, models: models)
    }

    private static func title(_ id: String, harness: Harness, models: [Harness: [ModelOption]]) -> String {
        if let option = models[harness]?.first(where: { $0.matches(id) }) { return option.title }
        if harness == .claude,
           let match = id.wholeMatch(of: /^claude-(opus|sonnet|haiku|fable)-(\d+)-(\d+)(?:-\d{8})?$/) {
            return "\(match.1.capitalized) \(match.2).\(match.3)"
        }
        return id
    }

    /// Nil when no one reported it: the label leaves effort out rather than guess or say "unavailable".
    static func effort(_ record: RunRecord, fallback: String? = nil) -> String? {
        guard let effort = record.reportedEffort ?? fallback ?? record.effort else { return nil }
        return effort == "none" ? "No effort" : effort.capitalized
    }
}

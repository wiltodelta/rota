import RotaCore

/// The harness and applied session model, by the title its CLI lists.
enum ModelLabel {
    static func name(record: RunRecord, models: [Harness: [ModelOption]]) -> String {
        guard let id = record.reportedModel ?? record.model else { return record.harness.title }
        let title = title(id, harness: record.harness, models: models, fallback: record.reportedModelTitle)
        return "\(record.harness.title)  \(title)"
    }

    static func model(record: RunRecord, models: [Harness: [ModelOption]], fallback: String? = nil) -> String {
        guard let id = record.reportedModel ?? fallback ?? record.model else {
            return record.outcome == .running ? "Resolving model…" : "Model unavailable"
        }
        return title(id, harness: record.harness, models: models, fallback: record.reportedModelTitle)
    }

    static func title(_ id: String, harness: Harness, models: [Harness: [ModelOption]],
                      fallback: String? = nil) -> String {
        if let option = models[harness]?.first(where: { $0.matches(id) }) { return option.title }
        if let fallback { return fallback }
        if harness == .claude,
           let match = id.wholeMatch(of: /^claude-(opus|sonnet|haiku|fable)-(\d+)-(\d+)(?:-\d{8})?$/) {
            return "\(match.1.capitalized) \(match.2).\(match.3)"
        }
        return id
    }

    /// Nil when no one reported it: the label leaves effort out rather than guess or say "unavailable".
    static func effort(_ record: RunRecord, fallback: String? = nil) -> String? {
        guard let effort = record.reportedEffort ?? fallback ?? record.effort else { return nil }
        return effortTitle(effort)
    }

    static func effortTitle(_ effort: String) -> String {
        effort == "none" ? "No effort" : effort.capitalized
    }

    static func configuration(_ routine: Routine, models: [Harness: [ModelOption]]) -> String {
        var parts = [routine.harness.title]
        if let id = routine.model ?? models[routine.harness]?.first(where: \.isDefault)?.id {
            parts.append(title(id, harness: routine.harness, models: models))
        }
        if let effort = routine.effort { parts.append(effortTitle(effort)) }
        return parts.joined(separator: " · ")
    }
}

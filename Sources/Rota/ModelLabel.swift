import RotaCore
import SwiftUI

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

extension RunRecord {
    /// This record as `mark`'s run reported it, for that run's labels; a mark without a model
    /// leaves the session's own values.
    func labeled(by mark: ConfigurationMark?) -> RunRecord {
        guard let mark, mark.model != nil else { return self }
        var record = self
        record.reportedModel = mark.model
        record.reportedModelTitle = mark.modelTitle
        record.reportedEffort = mark.effort
        return record
    }
}

/// The harness, resolved model and applied effort of the run that wrote the message: a session
/// continued on another model keeps each earlier answer's own label.
/// With a Copy button at the row's end for the message under it, shown while `hovering`.
struct AgentHeader: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let item: Int
    let copy: String
    let hovering: Bool

    var body: some View {
        // Without a mark (older sessions, logs without a journal) the session's own values stand.
        let labeled = record.labeled(by: record.configuration(at: item))
        HStack(spacing: metrics.points(6)) {
            HStack(spacing: metrics.points(6)) {
                HarnessLogo(harness: record.harness)
                Text(ModelLabel.name(record: labeled, models: model.settings.models))
                if let effort = ModelLabel.effort(labeled) {
                    Text(effort).foregroundStyle(Color.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            if !copy.isEmpty {
                Spacer(minLength: 0)
                CopyButton(text: copy, help: "Copy Message")
                    .foregroundStyle(Color.secondaryText)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .font(model.chatText.small)
    }
}

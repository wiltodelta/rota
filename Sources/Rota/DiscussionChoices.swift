import RotaCore
import SwiftUI

extension AppSettings {
    /// The model and effort remembered for discussions on `agent`, while its catalog offers them.
    func discussionSetup(for agent: Harness) -> ModelSetup {
        ModelSetup(harness: agent, settings: self, model: discussionModels[agent], effort: discussionEfforts[agent])
    }

    /// Remembers the model and effort for discussions on `agent`; nil leaves either to the agent.
    func setDiscussionChoice(_ agent: Harness, model: String?, effort: String?) {
        discussionModels[agent] = model
        discussionEfforts[agent] = effort
    }
}

extension AppModel {
    /// The remembered discussion agent while it is installed, else the first installed one.
    func discussionAgent(in choices: [(harness: Harness, installed: Bool)]) -> Harness? {
        choices.first { $0.harness == settings.discussionAgent && $0.installed }?.harness
            ?? choices.first(where: \.installed)?.harness
    }
}

/// The agents a Shell run can be discussed with, the chosen one checked; shared by the field's
/// agent picker and Session > Ask Agent About Run. The model is passed in: the menu bar's commands
/// have no `AppModel` in their environment, and reading it there traps.
struct DiscussionChoices: View {
    let model: AppModel
    let choices: [(harness: Harness, installed: Bool)]
    let agent: Harness?
    var picked: () -> Void = {}

    var body: some View {
        ForEach(choices, id: \.harness) { harness, installed in
            Toggle(harness.title, isOn: Binding(get: { harness == agent }, set: { _ in
                model.settings.discussionAgent = harness
                picked()
            }))
            .disabled(!installed)
            .accessibilityIdentifier("discussWith-\(harness.rawValue)")
        }
    }
}

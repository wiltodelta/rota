import RotaCore
import SwiftUI

/// A model and effort for one harness, as its catalog still offers them. A nil model or effort
/// leaves the choice to the harness. Before the catalog loads, a requested value stands: it was
/// picked from that catalog.
struct ModelSetup {
    let harness: Harness
    let options: [ModelOption]
    let loading: Bool
    let model: String?
    let effort: String?

    @MainActor
    init(harness: Harness, settings: AppSettings, model: String?, effort: String?) {
        self.harness = harness
        options = settings.models[harness] ?? []
        loading = settings.loadingModels.contains(harness)
        let resolved = options.isEmpty ? model : options.first { $0.matches(model) }?.id
        self.model = resolved
        self.effort = options.isEmpty ? effort : Self.effort(effort, offeredBy: Self.option(for: resolved, in: options))
    }

    /// The session's own next-run model and effort.
    @MainActor
    init(record: RunRecord, settings: AppSettings) {
        self.init(harness: record.harness, settings: settings, model: record.model, effort: record.effort)
    }

    /// The chosen model, else the one the harness runs by default; its efforts are the choices.
    var selected: ModelOption? { Self.option(for: model, in: options) }

    private static func option(for model: String?, in options: [ModelOption]) -> ModelOption? {
        options.first { $0.matches(model) } ?? options.first(where: \.isDefault)
    }

    private static func effort(_ effort: String?, offeredBy option: ModelOption?) -> String? {
        effort.flatMap { option?.efforts.contains($0) == true ? $0 : nil }
    }

    /// "Sonnet 4.6 · High" for a field's footer.
    var summary: String {
        let name = selected?.title ?? model.map { ModelLabel.title($0, harness: harness, models: [harness: options]) }
            ?? "Default model"
        return ([name] + [effort.map(ModelLabel.effortTitle)].compactMap { $0 }).joined(separator: " \u{00B7} ")
    }

    /// The effort to keep with `model`: the current one while that model offers it.
    func effort(keptWith model: String?) -> String? {
        Self.effort(effort, offeredBy: Self.option(for: model, in: options))
    }
}

/// Model and Effort submenus, from what the harness's CLI lists, as a routine's pickers offer
/// them. Used inside menus, including the menu bar's, so it takes no environment.
struct ModelEffortChoices: View {
    let setup: ModelSetup
    /// Prefixes the items' accessibility identifiers.
    let identifier: String
    let choose: (_ model: String?, _ effort: String?) -> Void

    var body: some View {
        Menu("Model") { models }
            .accessibilityIdentifier("\(identifier)ModelMenu")
        // `.disabled` does not reach a submenu inside a menu, so a model without adjustable
        // effort gets a dimmed item instead.
        if setup.selected?.efforts.isEmpty ?? true {
            Button("Effort") {}
                .disabled(true)
                .accessibilityIdentifier("\(identifier)EffortMenu")
        } else {
            Menu("Effort") { efforts }
                .accessibilityIdentifier("\(identifier)EffortMenu")
        }
    }

    @ViewBuilder
    private var models: some View {
        let fallback = setup.options.first(where: \.isDefault).map { "Default (\($0.title))" } ?? "Default"
        toggle(fallback, on: setup.model == nil, id: "Model-default") { choose(nil, setup.effort(keptWith: nil)) }
        if setup.options.isEmpty {
            Text(setup.loading ? "Loading Models\u{2026}" : "Couldn\u{2019}t Load Models")
        } else {
            Divider()
            ForEach(setup.options) { option in
                toggle(option.title, on: setup.model == option.id, id: "Model-\(option.id)") {
                    choose(option.id, setup.effort(keptWith: option.id))
                }
            }
        }
    }

    @ViewBuilder
    private var efforts: some View {
        toggle("Default", on: setup.effort == nil, id: "Effort-default") { choose(setup.model, nil) }
        Divider()
        ForEach(setup.selected?.efforts ?? [], id: \.self) { effort in
            toggle(ModelLabel.effortTitle(effort), on: setup.effort == effort, id: "Effort-\(effort)") {
                choose(setup.model, effort)
            }
        }
    }

    private func toggle(_ title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
            .accessibilityIdentifier(identifier + id)
    }
}

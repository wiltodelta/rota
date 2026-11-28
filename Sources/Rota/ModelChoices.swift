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

    /// The chosen model's title for a picker, else the harness's default.
    var modelTitle: String {
        selected?.title ?? model.map { ModelLabel.title($0, harness: harness, models: [harness: options]) }
            ?? "Default model"
    }

    /// The catalog lists the chosen model without an effort to choose. Before the catalog loads
    /// the effort picker still opens, as the model picker does, and says why it lists nothing.
    var effortFixed: Bool { !options.isEmpty && (selected?.efforts.isEmpty ?? true) }

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
        Menu("Model") { ModelItems(setup: setup, identifier: identifier, choose: choose) }
            .accessibilityIdentifier("\(identifier)ModelMenu")
        // `.disabled` does not reach a submenu inside a menu, so a model without adjustable
        // effort gets a dimmed item instead.
        if setup.effortFixed {
            Button("Effort") {}
                .disabled(true)
                .accessibilityIdentifier("\(identifier)EffortMenu")
        } else {
            Menu("Effort") { EffortItems(setup: setup, identifier: identifier, choose: choose) }
                .accessibilityIdentifier("\(identifier)EffortMenu")
        }
    }
}

/// The model and the effort as two independent pickers in a field's footer: each opens on its
/// own, and a model without adjustable effort dims the effort picker. Labels default to the
/// chosen values; a session passes what its harness resolved.
struct ModelEffortPickers: View {
    @Environment(\.interfaceScale) private var metrics
    let setup: ModelSetup
    var modelLabel: String?
    var effortLabel: String?
    let identifier: String
    let choose: (_ model: String?, _ effort: String?) -> Void

    var body: some View {
        let fixed = setup.effortFixed
        let effort = effortLabel ?? setup.effort.map(ModelLabel.effortTitle)
        HStack(spacing: metrics.points(10)) {
            FooterMenu(title: modelLabel ?? setup.modelTitle, help: "The model for the next message",
                       accessibilityLabel: "Model", identifier: identifier + "Model") {
                ModelItems(setup: setup, identifier: identifier, choose: choose)
            }
            .layoutPriority(-1)
            if !fixed || effort != nil {
                FooterMenu(title: effort ?? "Default effort",
                           help: fixed ? "This model has no reasoning effort setting"
                               : "The reasoning effort for the next message",
                           accessibilityLabel: "Reasoning Effort", identifier: identifier + "Effort", opens: !fixed) {
                    EffortItems(setup: setup, identifier: identifier, choose: choose)
                }
                .fixedSize()
            }
        }
    }
}

/// A borderless picker in a field's footer: its title, an optional leading mark and a chevron.
/// One that cannot open is disabled and shows no chevron, so it does not look like one that can.
struct FooterMenu<Items: View, Leading: View>: View {
    @Environment(\.interfaceScale) private var metrics
    let title: String
    let help: String
    let accessibilityLabel: String
    let identifier: String
    var opens = true
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder let items: () -> Items

    init(title: String, help: String, accessibilityLabel: String, identifier: String, opens: Bool = true,
         @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }, @ViewBuilder items: @escaping () -> Items) {
        self.title = title
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.identifier = identifier
        self.opens = opens
        self.leading = leading
        self.items = items
    }

    var body: some View {
        Menu(content: items) {
            HStack(spacing: metrics.points(4)) {
                HStack(spacing: metrics.points(6)) {
                    leading()
                    Text(title).truncationMode(.middle)
                }
                if opens { Image(systemName: "chevron.down").interfaceSystemFont(size: 9, weight: .semibold) }
            }
            .interfaceFont(.callout)
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!opens)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The models a harness lists, the chosen one checked, with its default first.
struct ModelItems: View {
    let setup: ModelSetup
    let identifier: String
    let choose: (_ model: String?, _ effort: String?) -> Void

    var body: some View {
        let fallback = setup.options.first(where: \.isDefault).map { "Default (\($0.title))" } ?? "Default"
        choiceToggle(fallback, on: setup.model == nil, id: "Model-default", prefix: identifier) {
            choose(nil, setup.effort(keptWith: nil))
        }
        if setup.options.isEmpty {
            Text(setup.loading ? "Loading Models\u{2026}" : "Couldn\u{2019}t Load Models")
        } else {
            Divider()
            ForEach(setup.options) { option in
                choiceToggle(option.title, on: setup.model == option.id, id: "Model-\(option.id)", prefix: identifier) {
                    choose(option.id, setup.effort(keptWith: option.id))
                }
            }
        }
    }
}

/// The efforts the chosen model offers, the chosen one checked; the model stays as it is.
struct EffortItems: View {
    let setup: ModelSetup
    let identifier: String
    let choose: (_ model: String?, _ effort: String?) -> Void

    var body: some View {
        choiceToggle("Default", on: setup.effort == nil, id: "Effort-default", prefix: identifier) {
            choose(setup.model, nil)
        }
        if setup.options.isEmpty {
            Text(setup.loading ? "Loading Models\u{2026}" : "Couldn\u{2019}t Load Models")
        } else {
            Divider()
            ForEach(setup.selected?.efforts ?? [], id: \.self) { effort in
                choiceToggle(ModelLabel.effortTitle(effort), on: setup.effort == effort,
                             id: "Effort-\(effort)", prefix: identifier) { choose(setup.model, effort) }
            }
        }
    }
}

private func choiceToggle(_ title: String, on: Bool, id: String, prefix: String,
                          action: @escaping () -> Void) -> some View {
    Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
        .accessibilityIdentifier(prefix + id)
}

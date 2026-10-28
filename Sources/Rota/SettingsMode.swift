import SwiftUI

/// Settings is a mode of the main window: the sidebar lists these sections in
/// place of routines and sessions, and the detail shows the selected one.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, chat, agents

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .chat: "Chat"
        case .agents: "Agents"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .chat: "textformat.size"
        case .agents: "terminal"
        }
    }

    static let lastKey = "settingsPane"

    /// The section Settings last showed, so it reopens there.
    static var last: SettingsPane {
        UserDefaults.standard.string(forKey: lastKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }
}

extension AppModel {
    func showSettings(_ pane: SettingsPane = .last) {
        if settingsPane == nil {
            selectionBeforeSettings = selection
            selection = nil
        }
        settingsPane = pane
        openMainWindow()
    }

    func closeSettings() {
        guard settingsPane != nil else { return }
        settingsPane = nil
        if selection == nil { selection = selectionBeforeSettings }
        selectionBeforeSettings = nil
    }
}

/// The sidebar in Settings: a way back, then the sections.
struct SettingsSidebar: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(\.appearsActive) private var appearsActive
    @Environment(AppModel.self) private var model
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        List(selection: Binding(get: { model.settingsPane }, set: { if let pane = $0 { model.settingsPane = pane } })) {
            Button { model.closeSettings() } label: {
                // The sidebar tints a label's icon with the accent; Back is one secondary control.
                Label {
                    Text("Back")
                } icon: {
                    Image(systemName: "chevron.left").foregroundStyle(Color.secondaryText)
                }
                .interfaceFont(.body)
                .foregroundStyle(Color.secondaryText)
                .frame(maxWidth: .infinity, minHeight: metrics.points(24), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Escape leaves Settings wherever focus is, as Back does.
            .keyboardShortcut(.cancelAction)
            .selectionDisabled()
            .help("Back to routines and sessions (Escape)")
            .accessibilityIdentifier("settingsBack")
            Section {
                ForEach(SettingsPane.allCases) { pane in
                    // The sidebar row style replaces a font set on the whole label, so set it on the parts.
                    Label {
                        Text(pane.title).interfaceFont(.body)
                    } icon: {
                        // Accent icons as in a native sidebar, contrasting on the focused selection.
                        let onAccent = appearsActive && sidebarFocused && model.settingsPane == pane
                        Image(systemName: pane.symbol).interfaceFont(.body)
                            .foregroundStyle(onAccent ? SidebarText.primary(onAccent: true) : Color.accentColor)
                    }
                    // The sidebar's own label spacing and row height stay at 100%.
                    .labelStyle(ScaledSidebarLabelStyle())
                    .frame(minHeight: metrics.points(24))
                    .tag(pane)
                    .accessibilityIdentifier("settingsPane-" + pane.rawValue)
                }
            } header: {
                SidebarHeader(title: "Settings")
            }
        }
        .accessibilityIdentifier("settingsSidebar")
        .focused($sidebarFocused)
    }
}

/// A sidebar label whose icon column and gap follow the interface scale.
private struct ScaledSidebarLabelStyle: LabelStyle {
    @Environment(\.interfaceScale) private var metrics

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: metrics.points(6)) {
            configuration.icon.frame(width: metrics.points(20))
            configuration.title
        }
    }
}

/// The selected section's grouped form.
struct SettingsDetail: View {
    let pane: SettingsPane

    var body: some View {
        // As in sessions and routines, a divider starts the scrolling content
        // below the title bar, so the form never scrolls under the title.
        VStack(spacing: 0) {
            Divider()
            switch pane {
            case .general: GeneralSettings()
            case .chat: ChatSettings()
            case .agents: AgentSettings()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

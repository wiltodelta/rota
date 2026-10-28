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
            Button { model.closeSettings() } label: { SidebarActionLabel(title: "Back", symbol: "chevron.left") }
            .buttonStyle(.plain)
            // Escape leaves Settings wherever focus is, as Back does.
            .keyboardShortcut(.cancelAction)
            .selectionDisabled()
            .help("Back to routines and sessions (Escape)")
            .accessibilityIdentifier("settingsBack")
            Section {
                ForEach(SettingsPane.allCases) { pane in
                    // On the focused selection, name and icon take the routine rows' contrasting foreground.
                    let onAccent = appearsActive && sidebarFocused && model.settingsPane == pane
                    // The sidebar row style replaces a font set on the whole label.
                    Label {
                        Text(pane.title).interfaceFont(.body)
                            .foregroundStyle(SidebarText.primary(onAccent: onAccent))
                    } icon: {
                        // Accent icons as in a native sidebar, near a harness mark's size.
                        Image(systemName: pane.symbol).font(.system(size: metrics.points(16)))
                            .foregroundStyle(onAccent ? SidebarText.primary(onAccent: true) : Color.accentColor)
                    }
                    .labelStyle(ScaledSidebarLabelStyle())
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

/// Settings pinned below the routines and sessions list, on the routine names' edge.
struct SidebarSettingsButton: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.showSettings() } label: { SidebarActionLabel(title: "Settings", symbol: "gearshape") }
        .buttonStyle(.plain)
        .padding(.leading, SidebarIconColumn.listInset)
        .padding(.trailing, metrics.points(12))
        .padding(.vertical, metrics.points(6))
        .overlay(alignment: .top) { Divider() }
        .help("Settings (Command-,)")
        .accessibilityIdentifier("sidebarSettings")
    }
}

/// A secondary sidebar action (Back, Settings) with a full-row target.
private struct SidebarActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .interfaceFont(.body)
            .foregroundStyle(Color.secondaryText)
            .labelStyle(ScaledSidebarLabelStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// A sidebar label in `SidebarIconColumn`, at the interface scale: the sidebar's
/// own label style keeps its gap and row height at 100%.
private struct ScaledSidebarLabelStyle: LabelStyle {
    @Environment(\.interfaceScale) private var metrics

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: metrics.points(SidebarIconColumn.gap)) {
            let side = metrics.points(SidebarIconColumn.width)
            configuration.icon.frame(width: side, height: side)
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

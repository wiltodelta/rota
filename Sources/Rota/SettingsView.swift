import AppKit
import os
import RotaCore
import ServiceManagement
import SwiftUI

/// The General tab: when Rota runs, what it tells you, updates and the terminal.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Notify when a run succeeds", isOn: $settings.notifyOnSuccess)
            } footer: {
                Text("Failed and skipped runs always notify.")
                    .foregroundStyle(Color.secondaryText)
            }
            Section {
                TerminalPicker()
            } footer: {
                Text("Open in Terminal and Continue in Terminal use it.")
                    .foregroundStyle(Color.secondaryText)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            } header: {
                Text("Startup")
            } footer: {
                Text(loginError.map { "Couldn't change this: \($0)" }
                     ?? "Start Rota automatically when you log in to your Mac. "
                     + "Rota runs routines only while it is open.")
                    .foregroundStyle(Color.secondaryText)
            }
            Section {
                LabeledContent("Version", value: Updater.shared.version)
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { Updater.shared.automaticallyChecks },
                    set: { Updater.shared.automaticallyChecks = $0 }
                ))
                Button("Check for Updates\u{2026}") { Updater.shared.checkForUpdates() }
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks once a day and installs a new version when you choose to.")
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .settingsPane()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            Logger(subsystem: "com.wiltodelta.rota", category: "settings")
                .error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The Chat tab: the chat's fonts and size.
struct ChatSettings: View {
    var body: some View {
        Form { ChatTextSection() }.settingsPane()
    }
}

/// The Agents tab: which copy of each agent CLI runs, and how Claude runs.
struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(Harness.agents) { harness in
                    ExecutablePicker(harness: harness)
                }
            } header: {
                Text("Agent CLIs")
            } footer: {
                Text("Rota lists the copies it finds on your login shell's PATH and in the usual install folders.")
                    .foregroundStyle(Color.secondaryText)
            }
            ClaudeModeSection()
        }
        .settingsPane()
        .onAppear { model.settings.refreshInstalled() }
    }
}

/// The Integrations tab: the rota command and agents' MCP access to routines.
struct IntegrationSettings: View {
    var body: some View {
        Form { AgentAccessSection() }.settingsPane()
    }
}

/// How Claude routines run: interactively, as in a terminal, or as `claude -p`,
/// and whether macOS lets them use the computer.
private struct ClaudeModeSection: View {
    @Environment(AppModel.self) private var model
    @State private var access = ComputerUseAccess.current()

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle("Run Claude Code interactively", isOn: $settings.claudeInteractive)
                .accessibilityIdentifier("claudeInteractive")
            if settings.claudeInteractive {
                PermissionRow(title: "Accessibility", granted: access.accessibility) {
                    ComputerUseAccess.requestAccessibility()
                }
                PermissionRow(title: "Screen Recording", granted: access.screenRecording) {
                    ComputerUseAccess.requestScreenRecording()
                }
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("As in a terminal: computer use where you turned it on in Claude Code, and Open in Terminal "
                 + "shows the live session. Computer use acts as Rota, so macOS asks Rota for these two. "
                 + "Folders Claude Code has not been trusted in run with claude -p.")
                .foregroundStyle(Color.secondaryText)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access = ComputerUseAccess.current()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow\u{2026}", action: request)
            }
        }
    }
}

extension View {
    /// A grouped form sized to its content, scrolling when a short screen requires it.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .frame(width: 520)
            // Reserve space for the title bar, toolbar and a margin above the Dock.
            .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) - 100)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Picks which installed copy of an agent CLI runs: the first one found, one
/// of the others, or any file chosen in an open panel.
private struct ExecutablePicker: View {
    @Environment(AppModel.self) private var model
    let harness: Harness
    private static let chooseTag = "\u{0}choose"

    var body: some View {
        let settings = model.settings
        let installed = settings.installed[harness] ?? []
        let chosen = settings.chosenExecutable(for: harness)
        let effective = settings.executable(for: harness)
        VStack(alignment: .leading, spacing: 4) {
            Picker(harness.title, selection: Binding(
                get: { chosen ?? "" },
                set: { choose($0) }
            )) {
                Text(installed.first.map { "Automatic (\(Self.display($0.path)))" } ?? "Automatic")
                    .tag("")
                Divider()
                ForEach(installed) { copy in
                    Text(Self.display(copy.path)).tag(copy.path)
                }
                if let chosen, !installed.contains(where: { $0.path == chosen }) {
                    Text(Self.display(chosen)).tag(chosen)
                }
                Divider()
                Text("Choose Other\u{2026}").tag(Self.chooseTag)
            }
            status(effective: effective, installed: installed)
        }
    }

    @ViewBuilder
    private func status(effective: String, installed: [InstalledExecutable]) -> some View {
        if !FileManager.default.isExecutableFile(atPath: effective) {
            Label("Not installed. Install \(harness.commandName) or choose its file.",
                  systemImage: "xmark.circle.fill")
                .foregroundStyle(Color.errorText)
                .font(.caption)
        } else if let version = installed.first(where: { $0.path == effective })?.version {
            Label(version, systemImage: "checkmark.circle.fill")
                .labelStyle(StatusLabelStyle())
                .font(.caption)
        }
    }

    private func choose(_ tag: String) {
        guard tag == Self.chooseTag else {
            model.settings.setExecutable(tag.isEmpty ? nil : tag, for: harness)
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Choose the \(harness.title) executable"
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (model.settings.executable(for: harness) as NSString)
            .deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.setExecutable(url.path, for: harness)
        model.settings.refreshInstalled()
    }

    static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Lets agent sessions create and manage routines: the `rota` command, and
/// `rota mcp` added to each agent CLI as an MCP server.
private struct AgentAccessSection: View {
    @Environment(AppModel.self) private var model
    @State private var commandInstalled = AgentAccess.commandInstalled()
    @State private var added: [Harness: Bool] = [:]
    @State private var busy: Harness?
    @State private var problem: String?

    var body: some View {
        Section {
            LabeledContent {
                if commandInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill").labelStyle(StatusLabelStyle())
                } else {
                    Button("Install") { installCommand() }
                }
            } label: {
                Text("rota command")
                Text(AgentAccess.commandLink().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
            ForEach(Harness.agents) { harness in
                LabeledContent(harness.title) {
                    if busy == harness {
                        ProgressView().controlSize(.small)
                    } else if let isAdded = added[harness] {
                        Button(isAdded ? "Remove" : "Add") { change(harness, add: !isAdded) }
                            .accessibilityIdentifier("agentAccess-\(harness.rawValue)")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Color.errorText)
            }
        } header: {
            Text("Routines from agents")
        } footer: {
            Text("An agent with Rota added can create, change, run and read routines; a routine it adds runs on its "
                 + "schedule and Rota tells you. In a terminal, run rota help.")
                .foregroundStyle(Color.secondaryText)
        }
        .task { await refresh() }
    }

    private func installCommand() {
        do {
            try AgentAccess.installCommand()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        commandInstalled = AgentAccess.commandInstalled()
    }

    private func change(_ harness: Harness, add: Bool) {
        // The agents run the command from the link, so it has to exist first.
        if add, !commandInstalled { installCommand() }
        guard !add || commandInstalled else { return }
        busy = harness
        let executable = model.settings.executable(for: harness)
        Task {
            let failure = await Task.detached { AgentAccess.change(harness, add: add, executable: executable) }.value
            problem = failure.map { "\(harness.title): \($0)" }
            await refresh()
            busy = nil
        }
    }

    private func refresh() async {
        let executables = Dictionary(uniqueKeysWithValues: Harness.agents.map {
            ($0, model.settings.executable(for: $0))
        })
        let found = await Task.detached {
            await withTaskGroup(of: (Harness, Bool).self) { group in
                for (harness, executable) in executables {
                    group.addTask { (harness, AgentAccess.isAdded(harness, executable: executable)) }
                }
                return await group.reduce(into: [Harness: Bool]()) { $0[$1.0] = $1.1 }
            }
        }.value
        added = found
    }
}

/// The terminal app sessions open in: the one macOS treats as the default, an
/// installed terminal Rota knows, or any app chosen in an open panel.
private struct TerminalPicker: View {
    @Environment(AppModel.self) private var model
    @State private var installed: [KnownTerminal] = []
    @State private var handler: URL?
    private static let chooseTag = "\u{0}choose"

    var body: some View {
        let chosen = model.settings.terminalApp
        // A closure, not `set: choose`: Swift 6.3.3 (Xcode 26.6) crashed in IRGen on the
        // method reference's @isolated(any) thunk.
        Picker("Terminal", selection: Binding(get: { chosen ?? "" }, set: { choose($0) })) {
            Text(handler.map { "Default (\(Self.name($0.path)))" } ?? "Default").tag("")
            Divider()
            ForEach(installed, id: \.self) { terminal in
                if let url = terminal.url { Text(terminal.title).tag(url.path) }
            }
            if let chosen, !installed.contains(where: { $0.url?.path == chosen }) {
                Text(Self.name(chosen)).tag(chosen)
            }
            Divider()
            Text("Choose Other\u{2026}").tag(Self.chooseTag)
        }
        .accessibilityIdentifier("terminalApp")
        .task {
            installed = TerminalLauncher.installed()
            handler = TerminalLauncher.defaultTerminal()
        }
    }

    private func choose(_ tag: String) {
        guard tag == Self.chooseTag else {
            model.settings.terminalApp = tag.isEmpty ? nil : tag
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Choose the terminal app sessions open in"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.terminalApp = url.path
    }

    /// A known terminal's own title, so the default reads as the list below does.
    static func name(_ path: String) -> String {
        Bundle(path: path)?.bundleIdentifier.flatMap(KnownTerminal.init(rawValue:))?.title
            ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }
}

/// A green check before secondary text, as the status under a picker reads.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.green)
            configuration.title.foregroundStyle(Color.secondaryText)
        }
    }
}

/// Font, monospaced font and size of the chat, with a sample in them.
private struct ChatTextSection: View {
    @Environment(AppModel.self) private var model
    @State private var families: [String] = []
    @State private var monospaced: [String] = []

    var body: some View {
        @Bindable var text = model.chatText
        Section("Chat text") {
            Picker("Font", selection: $text.family) {
                Text("System").tag("")
                Divider()
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            Picker("Code font", selection: $text.codeFamily) {
                Text("System monospaced").tag("")
                Divider()
                ForEach(monospaced, id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Size") {
                HStack {
                    Slider(value: $text.size, in: ChatTextSettings.sizes, step: 1)
                    Text("\(Int(text.size)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Clicks are down 8% week over week.").font(text.body)
                Text("$ git log --oneline -5").font(text.code).foregroundStyle(Color.secondaryText)
            }
            .padding(.vertical, 4)
            .accessibilityLabel("Sample")
        }
        .task {
            families = ChatTextSettings.families
            monospaced = ChatTextSettings.monospacedFamilies
        }
    }
}

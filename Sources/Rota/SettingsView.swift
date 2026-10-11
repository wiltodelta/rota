import AppKit
import os
import RotaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).foregroundStyle(.red).font(.caption)
                }
                Toggle("Notify when a run succeeds", isOn: $settings.notifyOnSuccess)
            } footer: {
                Text("Rota runs routines only while it is open. Failed and skipped runs always notify.")
            }
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { Updater.shared.automaticallyChecks },
                    set: { Updater.shared.automaticallyChecks = $0 }
                ))
                LabeledContent("Version \(Updater.shared.version)") {
                    Button("Check for Updates\u{2026}") { Updater.shared.checkForUpdates() }
                }
            }
            ChatTextSection()
            AgentAccessSection()
            Section {
                TerminalPicker()
            } footer: {
                Text("Open in Terminal and Continue in Terminal use it.")
            }
            Section {
                ForEach(Harness.agents) { harness in
                    ExecutablePicker(harness: harness)
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Rota lists the copies it finds on your login shell's PATH and in the usual install folders.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.settings.refreshInstalled() }
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
                .foregroundStyle(.red)
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
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Routines from agents")
        } footer: {
            Text("An agent with Rota added can create, change, run and read routines; a routine it adds runs on its "
                 + "schedule and Rota tells you. In a terminal, run rota help.")
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
        Picker("Terminal", selection: Binding(get: { chosen ?? "" }, set: choose)) {
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
            configuration.title.foregroundStyle(.secondary)
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
                Text("$ git log --oneline -5").font(text.code).foregroundStyle(.secondary)
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

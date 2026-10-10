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

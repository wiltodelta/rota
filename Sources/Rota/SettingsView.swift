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
            Section("Harness executables") {
                ForEach(Harness.allCases) { harness in
                    ExecutableField(harness: harness)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
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

private struct ExecutableField: View {
    @Environment(AppModel.self) private var model
    let harness: Harness
    @State private var path = ""

    var body: some View {
        let found = FileManager.default.isExecutableFile(atPath: model.settings.executable(for: harness))
        LabeledContent(harness.title) {
            HStack {
                TextField(harness.title, text: $path, prompt: Text(harness.defaultExecutable()))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .onSubmit { model.settings.setExecutable(path, for: harness) }
                Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(found ? .green : .red)
                    .help(found ? "Found" : "No executable at this path")
            }
        }
        .onAppear {
            path = model.settings.executable(for: harness) == harness.defaultExecutable()
                ? "" : model.settings.executable(for: harness)
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

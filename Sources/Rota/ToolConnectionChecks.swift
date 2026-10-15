import AppKit
import RotaCore
import SwiftUI

@MainActor
@Observable
final class ToolConnectionChecks {
    struct Result {
        var evidence: ToolConnectionEvidence
        var date: Date
        var log: URL
        var context: String
        var detail: String
    }

    var folder = NSHomeDirectory()
    private(set) var results: [Harness: Result] = [:]
    private(set) var checking: Harness?
    @ObservationIgnored private var control: RunControl?

    func context(_ harness: Harness, settings: AppSettings) -> String {
        "\(folder)|\(settings.executable(for: harness))|\(settings.claudeInteractive)"
    }

    func start(_ harness: Harness, settings: AppSettings) {
        guard checking == nil else { return }
        checking = harness
        let captured = context(harness, settings: settings)
        let directory = StorageLocation.standard.logs.appendingPathComponent("connection-checks")
        let log = directory.appendingPathComponent("\(harness.rawValue)-\(UUID().uuidString).log")
        let claude = harness == .claude ? ClaudeUserSettings.read() : ClaudeUserSettings()
        var spec = LaunchSpec(executable: settings.executable(for: harness), prompt: Self.prompt,
                              arguments: harness.arguments(settings: claude), workingDirectory: folder,
                              environment: ["ROTA_CLI": AgentAccess.helper().path],
                              mode: harness.launchMode, timeout: 120, log: log)
        if harness == .claude && settings.claudeInteractive && claude.trusts(folder) {
            spec.mode = .claudeInteractive
        }
        let events = RunEvents(session: { _ in }, finished: { [weak self] outcome in
            guard let self else { return }
            let reader = SessionEventReader()
            do {
                try reader.read(from: SessionEventReader.file(for: log))
                let evidence = ToolConnectionEvidence(items: reader.transcript.items)
                self.results[harness] = Result(evidence: evidence, date: Date(), log: log, context: captured,
                                               detail: evidence.failure ?? (outcome == .succeeded
                                                ? "Only successful native browser tool calls count as connected."
                                                : outcome.title))
            } catch {
                self.results[harness] = Result(evidence: .init(items: []), date: Date(), log: log,
                                               context: captured, detail: "Could not read the check results.")
            }
            self.checking = nil
            self.control = nil
        }, requests: { [weak self] requests in
            if !requests.isEmpty { self?.control?.stop() }
        })
        do { control = try ProcessLauncher().launch(spec, events: events) } catch {
            results[harness] = Result(evidence: .init(items: []), date: Date(), log: log, context: captured,
                                      detail: error.localizedDescription)
            checking = nil
        }
    }

    func stop() { control?.stop() }

    private static let prompt = """
    Check native browser connections in this harness using existing settings and tools only.
    Do not run any routine, skill or project task. Do not change files, settings, permissions,
    browser accounts or grants. Do not send messages. Do not use shell, HTTP, Playwright,
    an isolated browser or external MCP servers as substitutes for native browser integrations.
    Test Chrome with the harness's native Chrome integration by reading its connected-browser inventory.
    Independently test the harness's native Browser Use integration by reading its browser/tab
    inventory. In Claude Code, Claude in Chrome is the native browser integration. In Codex,
    use its native cua_repl browser interface. In Claude, call list_connected_browsers, not
    tabs_context_mcp, because a missing tab group does not establish browser connectivity.
    If a tool is missing, say unavailable; do not
    install or enable anything. Follow tool bootstrap instructions. Do not navigate existing tabs,
    create tabs, read page content, click or type. If permission or sign-in is needed, stop that
    probe. Finish with a brief status for Chrome and native Browser Use and the exact blocker.
    """
}

struct BrowserConnectionSettings: View {
    var body: some View {
        Form { ToolConnectionsSection() }.settingsPane()
    }
}

struct ToolConnectionsSection: View {
    @Environment(AppModel.self) private var model
    @State private var checks = ToolConnectionChecks()

    var body: some View {
        Section {
            LabeledContent("Project folder") {
                Button((checks.folder as NSString).abbreviatingWithTildeInPath) { chooseFolder() }
                    .lineLimit(1).truncationMode(.middle)
                    .disabled(checks.checking != nil)
                    .accessibilityIdentifier("connectionCheckFolder")
            }
            ForEach(Harness.agents) { harness in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(harness.title).fontWeight(.medium)
                        Spacer()
                        if checks.checking == harness {
                            ProgressView().controlSize(.small)
                            Button("Stop") { checks.stop() }
                        } else {
                            Button("Check Connection") { checks.start(harness, settings: model.settings) }
                                .disabled(checks.checking != nil)
                                .accessibilityIdentifier("checkConnection-\(harness.rawValue)")
                        }
                    }
                    let result = checks.results[harness].flatMap {
                        $0.context == checks.context(harness, settings: model.settings) ? $0 : nil
                    }
                    HStack(spacing: 20) {
                        status("Chrome", connected: result?.evidence.chrome, harness: harness)
                        status("Browser Use", connected: result?.evidence.browser, harness: harness)
                    }
                    if let result {
                        Text(result.detail).interfaceFont(.caption).foregroundStyle(Color.primary)
                        HStack {
                            Text("Checked \(result.date.formatted(date: .abbreviated, time: .shortened))")
                                .interfaceFont(.caption).foregroundStyle(Color.primary)
                            Spacer()
                            Button("Open Check Log") { NSWorkspace.shared.open(result.log) }
                                .controlSize(.small)
                                .disabled(!FileManager.default.fileExists(atPath: result.log.path))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Browser connections")
        } footer: {
            Text("Checks use a short agent session and your selected folder's settings. They may use quota. "
                 + "Not confirmed means no successful native tool result was received. Permissions are not changed.")
                .foregroundStyle(Color.primary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            checks.stop()
        }
    }

    private func status(_ title: String, connected: Bool?, harness: Harness) -> some View {
        let value = checks.checking == harness ? "Checking…"
            : connected.map { $0 ? "Connected" : "Not confirmed" } ?? "Not checked"
        return Text("\(title): \(value)").interfaceFont(.caption).foregroundStyle(Color.primary)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the project folder whose agent settings you want to check"
        if panel.runModal() == .OK, let url = panel.url { checks.folder = url.path }
    }
}

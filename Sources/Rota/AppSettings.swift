import Foundation
import RotaCore
import SwiftUI

/// User preferences kept in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var notifyOnSuccess: Bool {
        didSet { defaults.set(notifyOnSuccess, forKey: "notifyOnSuccess") }
    }

    private var executables: [String: String] {
        didSet { defaults.set(executables, forKey: "executables") }
    }

    /// The terminal app sessions open in; nil follows the macOS default terminal.
    var terminalApp: String? {
        didSet { defaults.set(terminalApp, forKey: "terminalApp") }
    }

    /// Claude routines run as an interactive `claude` (on by default), else as `claude -p`.
    var claudeInteractive: Bool {
        didSet { defaults.set(claudeInteractive, forKey: "claudeInteractive") }
    }

    init() {
        notifyOnSuccess = defaults.bool(forKey: "notifyOnSuccess")
        executables = defaults.dictionary(forKey: "executables") as? [String: String] ?? [:]
        terminalApp = defaults.string(forKey: "terminalApp")
        claudeInteractive = defaults.object(forKey: "claudeInteractive") as? Bool ?? true
        refreshInstalled()
    }

    /// The installed copies of each agent CLI, found at launch and when Settings open.
    private(set) var installed: [Harness: [InstalledExecutable]] = [:]
    /// The models each agent offers, read from its CLI with the copies.
    private(set) var models: [Harness: [ModelOption]] = [:]

    /// The path runs use: the one picked in Settings, else the first installed
    /// copy, else where the CLI's installer puts it. The shell is always zsh.
    func executable(for harness: Harness) -> String {
        harness == .shell ? harness.defaultExecutable()
            : Self.resolve(harness, chosen: chosenExecutable(for: harness), installed: installed[harness] ?? [])
    }

    private nonisolated static func resolve(_ harness: Harness, chosen: String?,
                                            installed: [InstalledExecutable]) -> String {
        chosen ?? installed.first?.path ?? harness.defaultExecutable()
    }

    /// The path picked in Settings; nil means automatic.
    func chosenExecutable(for harness: Harness) -> String? {
        executables[harness.rawValue].flatMap { $0.isEmpty ? nil : $0 }
    }

    func setExecutable(_ path: String?, for harness: Harness) {
        executables[harness.rawValue] = path
    }

    @ObservationIgnored private var refreshing: Task<Void, Never>?

    /// Finds the installed copies, then each agent's models, all agents at once.
    /// A newer call replaces one still running, so the latest choices win.
    func refreshInstalled() {
        let chosen = Dictionary(uniqueKeysWithValues: Harness.agents.map { ($0, chosenExecutable(for: $0)) })
        refreshing?.cancel()
        refreshing = Task.detached(priority: .utility) {
            let found = ExecutableDiscovery.installedAgents()
            guard !Task.isCancelled else { return }
            await MainActor.run { self.installed = found }
            let models = await withTaskGroup(of: (Harness, [ModelOption]).self) { group in
                for harness in Harness.agents {
                    let executable = Self.resolve(harness, chosen: chosen[harness] ?? nil,
                                                  installed: found[harness] ?? [])
                    group.addTask { (harness, ModelCatalog.models(for: harness, executable: executable)) }
                }
                return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self.models = models }
        }
    }
}

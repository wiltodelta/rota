import Foundation
import RotaCore
import SwiftUI

/// User preferences kept in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

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

    init(defaults: UserDefaults = .standard, refreshOnInit: Bool = true) {
        self.defaults = defaults
        notifyOnSuccess = defaults.bool(forKey: "notifyOnSuccess")
        executables = defaults.dictionary(forKey: "executables") as? [String: String] ?? [:]
        terminalApp = defaults.string(forKey: "terminalApp")
        claudeInteractive = defaults.object(forKey: "claudeInteractive") as? Bool ?? true
        if refreshOnInit { refreshInstalled() }
    }

    /// The installed copies of each agent CLI, found at launch and when Settings open.
    private(set) var installed: [Harness: [InstalledExecutable]] = [:]
    /// The models each agent offers, read from its CLI with the copies.
    private(set) var models: [Harness: [ModelOption]] = [:]
    private(set) var loadingModels = Set<Harness>()

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
    /// Publish each catalog as it arrives; a slow CLI must not hold up another.
    /// A newer call replaces one still running, so the latest choices win.
    @discardableResult
    func refreshInstalled(
        discover: @escaping @Sendable () -> [Harness: [InstalledExecutable]] = {
            ExecutableDiscovery.installedAgents()
        },
        catalog: @escaping @Sendable (Harness, String) async -> [ModelOption] = {
            ModelCatalog.models(for: $0, executable: $1)
        }
    ) -> Task<Void, Never> {
        let chosen = Dictionary(uniqueKeysWithValues: Harness.agents.map { ($0, chosenExecutable(for: $0)) })
        refreshing?.cancel()
        loadingModels = Set(Harness.agents)
        let refresh = Task.detached(priority: .utility) {
            let found = discover()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.installed = found
            }
            await withTaskGroup(of: (Harness, [ModelOption]).self) { group in
                for harness in Harness.agents {
                    let executable = Self.resolve(harness, chosen: chosen[harness] ?? nil,
                                                  installed: found[harness] ?? [])
                    group.addTask { (harness, await catalog(harness, executable)) }
                }
                for await (harness, options) in group {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.models[harness] = options
                        self.loadingModels.remove(harness)
                    }
                }
            }
        }
        refreshing = refresh
        return refresh
    }
}

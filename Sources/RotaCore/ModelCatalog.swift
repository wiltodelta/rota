import Foundation

/// A model a routine can run on, with the reasoning efforts it takes.
public struct ModelOption: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var efforts: [String]
    /// The harness runs this one when the routine names none.
    public var isDefault: Bool
    public var aliases: [String]

    public init(id: String, title: String, efforts: [String], isDefault: Bool = false, aliases: [String] = []) {
        self.id = id
        self.title = title
        self.efforts = efforts
        self.isDefault = isDefault
        self.aliases = aliases
    }

    /// A native variant's label without the separately displayed reasoning tier.
    static func title(_ label: String, effort: String) -> String {
        let suffix = " (\(effort.capitalized))"
        return label.hasSuffix(suffix) ? String(label.dropLast(suffix.count)) : label
    }

    public func matches(_ value: String?) -> Bool {
        guard let value else { return false }
        return id == value || aliases.contains(value)
    }
}

/// The models each harness offers, read from the CLI where it can list them.
/// Listing spends no quota: Codex answers `model/list` and Grok `grok models`
/// without a prompt. Claude answers control initialization with resolved model
/// IDs, display names and supported efforts, without starting a model turn.
public enum ModelCatalog {
    /// Blocks while the CLI answers: call it off the main thread.
    public static func models(for harness: Harness, executable: String) -> [ModelOption] {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return [] }
        switch harness {
        case .claude:
            return ClaudeConfiguration.read(executable: executable, directory: NSTemporaryDirectory())?.models ?? []
        case .codex: return codexModels(executable: executable)
        case .grok: return grokModels(executable: executable)
        case .antigravity: return AntigravityCatalog.read(executable: executable)
        case .shell: return []
        }
    }

    static func parseClaudeModels(_ value: Any) -> [ModelOption] {
        let rows = (value as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let defaultID = rows.first { $0["value"] as? String == "default" }?["resolvedModel"] as? String
        var options: [ModelOption] = []
        for row in rows where row["value"] as? String != "default" {
            guard let id = row["resolvedModel"] as? String,
                  let title = row["displayName"] as? String, !id.isEmpty else { continue }
            let alias = row["value"] as? String
            if let index = options.firstIndex(where: { $0.id == id }) {
                if let alias, alias != id { options[index].aliases.append(alias) }
                continue
            }
            options.append(ModelOption(id: id, title: title,
                                       efforts: row["supportedEffortLevels"] as? [String] ?? [],
                                       isDefault: id == defaultID, aliases: alias.map { $0 == id ? [] : [$0] } ?? []))
        }
        return options
    }

    static func grokModels(executable: String) -> [ModelOption] {
        if let models = GrokCatalog.read(executable: executable) { return models }
        let (status, output) = ProcessLauncher.capture(executable, ["models"], in: NSTemporaryDirectory(),
                                                       timeout: 10, errors: false)
        return status == 0 ? parseGrokModels(output) : []
    }

    /// `grok models` prints one model per line, `* id (default)` or `- id`.
    static func parseGrokModels(_ text: String) -> [ModelOption] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") else { return nil }
            let words = trimmed.dropFirst(2).split(separator: " ")
            guard let id = words.first.map(String.init) else { return nil }
            return ModelOption(id: id, title: id, efforts: [], isDefault: words.contains("(default)"))
        }
    }

    static func codexModels(executable: String, timeout: TimeInterval = 10) -> [ModelOption] {
        let process = ProcessLauncher.loginShellProcess(executable, ["app-server"], in: NSTemporaryDirectory(),
                                                        environment: [:])
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        defer { process.terminate() }
        let peer = JSONRPCPeer(transport: LineTransport(input: stdin.fileHandleForWriting,
                                                        output: stdout.fileHandleForReading))
        let done = DispatchSemaphore(value: 0)
        var models: [ModelOption] = []
        peer.onClose = { done.signal() }
        peer.request("initialize", ["clientInfo": ["name": "rota", "version": "1"]]) { _ in
            peer.notify("initialized")
            peer.request("model/list", [:]) { result in
                if case .success(let value) = result { models = parseCodexModels(value) }
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + timeout)
        peer.close()
        return models
    }

    /// The visible models of a `model/list` reply, with the efforts each supports.
    static func parseCodexModels(_ value: Any) -> [ModelOption] {
        let data = (value as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return data.compactMap { model in
            guard let id = model["id"] as? String, model["hidden"] as? Bool != true else { return nil }
            let efforts = (model["supportedReasoningEfforts"] as? [Any] ?? []).compactMap { effort in
                (effort as? [String: Any])?["reasoningEffort"] as? String ?? effort as? String
            }
            return ModelOption(id: id, title: model["displayName"] as? String ?? id, efforts: efforts,
                               isDefault: model["isDefault"] as? Bool == true)
        }
    }
}

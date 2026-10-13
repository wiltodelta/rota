import Foundation

/// A model a routine can run on, with the reasoning efforts it takes.
public struct ModelOption: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var efforts: [String]
    /// The harness runs this one when the routine names none.
    public var isDefault: Bool

    public init(id: String, title: String, efforts: [String], isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.efforts = efforts
        self.isDefault = isDefault
    }
}

/// The models each harness offers, read from the CLI where it can list them.
/// Listing spends no quota: Codex answers `model/list` and Grok `grok models`
/// without a prompt. Claude's stream-json initialization lists available models,
/// their resolved versions and supported efforts, also without a prompt.
public enum ModelCatalog {
    /// The `reasoning_effort` options of a Grok ACP session, 2026-10-09.
    static let grokEfforts = ["low", "medium", "high", "xhigh"]

    /// Blocks while the CLI answers: call it off the main thread.
    public static func models(for harness: Harness, executable: String) -> [ModelOption] {
        switch harness {
        case .claude: return claudeModels(executable: executable)
        case .codex: return codexModels(executable: executable)
        case .grok: return grokModels(executable: executable)
        case .shell: return []
        }
    }

    static func grokModels(executable: String) -> [ModelOption] {
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
            return ModelOption(id: id, title: id, efforts: grokEfforts, isDefault: words.contains("(default)"))
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

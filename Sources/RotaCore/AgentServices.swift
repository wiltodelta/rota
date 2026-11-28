import Foundation

public enum ImportSource: String, CaseIterable, Codable, Sendable {
    case claudeDesktop
    case codex

    public var title: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .codex: return "Codex"
        }
    }

    public var harness: Harness {
        switch self {
        case .claudeDesktop: return .claude
        case .codex: return .codex
        }
    }
}

public struct ImportCandidate: Identifiable, Equatable, Codable, Sendable {
    public var routine: Routine
    public var source: ImportSource
    public var onInSource: Bool
    public var unsupported: String?

    public var id: String {
        routine.importIdentity ?? "\(source.rawValue):\(routine.id)"
    }

    public init(
        routine: Routine,
        source: ImportSource,
        onInSource: Bool,
        unsupported: String? = nil,
        sourceID: String? = nil
    ) {
        self.routine = routine
        self.source = source
        self.onInSource = onInSource
        self.unsupported = unsupported
        if let sourceID {
            self.routine.importIdentity = "\(source.rawValue):\(sourceID)"
        }
    }
}

public struct ImportScan: Decodable, Sendable {
    public var source: ImportSource
    public var candidates: [ImportCandidate]
    public var problem: String?

    public init(source: ImportSource, candidates: [ImportCandidate], problem: String? = nil) {
        self.source = source
        self.candidates = candidates
        self.problem = problem
    }
}

public enum RoutineImport {
    public static func scanAll(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportScan] {
        (try? FFIBridge.callCore([ImportScan].self, "import.scanAll", params: ["home": home.path])) ?? []
    }

    public static func isImported(_ candidate: ImportCandidate, in routines: [Routine]) -> Bool {
        guard let candJSON = FFIJSON.toJSONValue(candidate) else { return false }
        return (try? FFIBridge.callCore(Bool.self, "import.isImported", params: [
            "candidate": candJSON,
            "routines": FFIJSON.toJSONValue(routines) ?? []
        ])) ?? false
    }

    public static func routineToImport(_ candidate: ImportCandidate, existing: [Routine]) -> Routine? {
        guard let candJSON = FFIJSON.toJSONValue(candidate) else { return nil }
        return try? FFIBridge.callCore(Routine?.self, "import.routineToImport", params: [
            "candidate": candJSON,
            "existing": FFIJSON.toJSONValue(existing) ?? []
        ])
    }
}

public struct InstalledExecutable: Hashable, Identifiable, Decodable, Sendable {
    public var path: String
    public var version: String?
    public var id: String { path }

    public init(path: String, version: String? = nil) {
        self.path = path
        self.version = version
    }
}

public enum ExecutableDiscovery {
    public static func installedAgents() -> [Harness: [InstalledExecutable]] {
        guard let raw = try? FFIBridge.callCore(
            [String: [InstalledExecutable]].self,
            "discovery.installedAgents"
        ) else {
            return [:]
        }
        var mapped: [Harness: [InstalledExecutable]] = [:]
        for (key, list) in raw {
            if let harness = Harness(rawValue: key) {
                mapped[harness] = list
            }
        }
        return mapped
    }
}

public struct ModelOption: Hashable, Identifiable, Codable, Sendable {
    public var id: String
    public var title: String
    public var efforts: [String]
    public var isDefault: Bool
    public var aliases: [String]

    public init(
        id: String,
        title: String,
        efforts: [String],
        isDefault: Bool = false,
        aliases: [String] = []
    ) {
        self.id = id
        self.title = title
        self.efforts = efforts
        self.isDefault = isDefault
        self.aliases = aliases
    }

    public func matches(_ value: String?) -> Bool {
        guard let value else { return false }
        return id == value || aliases.contains(value)
    }
}

public enum ModelCatalog {
    public static func models(for harness: Harness, executable: String) -> [ModelOption] {
        (try? FFIBridge.callCore([ModelOption].self, "catalog.models", params: [
            "harness": harness.rawValue,
            "executable": executable
        ])) ?? []
    }
}

public struct ClaudeConfiguration: Decodable, Sendable {
    public var session: SessionConfiguration
    public var models: [ModelOption]

    public static func read(
        executable: String,
        directory: String,
        model: String? = nil,
        effort: String? = nil,
        resume: String? = nil,
        timeout: TimeInterval = 8
    ) -> ClaudeConfiguration? {
        var params: [String: Any] = [
            "executable": executable,
            "directory": directory,
            "timeoutSecs": timeout
        ]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        if let resume { params["resume"] = resume }
        return try? FFIBridge.callCore(ClaudeConfiguration?.self, "claudeConfig.read", params: params)
    }
}

public enum AgentAccess {
    public static func commandLink(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/rota")
    }

    public static func helper(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/rota")
    }

    public static func commandInstalled(link: URL = commandLink(), helper: URL = helper()) -> Bool {
        (try? FFIBridge.callCore(Bool.self, "agentAccess.commandInstalled", params: [
            "link": link.path,
            "helper": helper.path
        ])) ?? false
    }

    public static func installCommand(link: URL = commandLink(), helper: URL = helper()) throws {
        _ = try FFIBridge.callCore(Bool.self, "agentAccess.installCommand", params: [
            "link": link.path,
            "helper": helper.path
        ])
    }

    public static func isAdded(_ harness: Harness, executable: String) -> Bool {
        (try? FFIBridge.callCore(Bool.self, "agentAccess.isAdded", params: [
            "harness": harness.rawValue,
            "executable": executable
        ])) ?? false
    }

    public static func change(
        _ harness: Harness,
        add: Bool,
        executable: String,
        command: String = helper().path
    ) -> String? {
        try? FFIBridge.callCore(String?.self, "agentAccess.change", params: [
            "harness": harness.rawValue,
            "add": add,
            "executable": executable,
            "command": command
        ])
    }
}

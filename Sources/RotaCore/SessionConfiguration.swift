import Foundation

/// Values reported by a harness, kept separately from requested model/effort overrides.
public struct SessionConfiguration: Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var modelTitle: String?

    public init(model: String? = nil, effort: String? = nil, modelTitle: String? = nil) {
        self.model = Self.value(model)
        self.effort = Self.value(effort)
        self.modelTitle = Self.value(modelTitle)
    }

    /// Shared ACP configuration shape from live replies and archived updates.
    static func acp(_ value: Any) -> SessionConfiguration {
        let options = (value as? [String: Any])?["configOptions"] as? [[String: Any]] ?? []
        let model = options.first { $0["id"] as? String == "model" }?["currentValue"] as? String
        let effort = options.first { $0["id"] as? String == "reasoning_effort" }?["currentValue"] as? String
        return SessionConfiguration(model: model, effort: effort)
    }

    private static func value(_ text: String?) -> String? {
        text.flatMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value == "unknown model" ? nil : value
        }
    }

    /// Best-effort compatibility with Rota's readable headers, bounded and off the UI actor.
    public static func recordedModel(log: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        try? file.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? file.readToEnd() else { return nil }
        for line in lossyUTF8(data).split(separator: "\n").reversed() {
            guard line.hasSuffix("]"),
                  ["[session started, ", "[codex thread ", "[grok session "].contains(where: line.hasPrefix),
                  let comma = line.firstIndex(of: ",") else { continue }
            return value(String(line[line.index(after: comma)..<line.index(before: line.endIndex)]))
        }
        return nil
    }
}

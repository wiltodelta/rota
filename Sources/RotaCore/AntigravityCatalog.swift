import Foundation
import os

/// Reads model families and their own effort tiers through agy's read-only slash
/// commands. These return command metadata without a turn or a saved conversation.
enum AntigravityCatalog {
    struct Row: Equatable {
        var id: String
        var title: String

        /// A candidate alias only. Never exposed until /model confirms it resolves
        /// to one of this group's listed variants.
        var candidate: String {
            guard let separator = id.lastIndex(of: "-"),
                  ["low", "medium", "high", "xhigh", "max"].contains(String(id[id.index(after: separator)...]))
            else { return id }
            return String(id[..<separator])
        }
    }

    static func rows(_ text: String) -> [Row] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return Row(id: fields[0], title: fields[1])
        }
    }

    static func read(executable: String) -> [ModelOption] {
        let (status, output) = ProcessLauncher.capture(executable, ["models"], in: NSTemporaryDirectory(),
                                                       timeout: 15, errors: false)
        guard status == 0 else { return [] }
        let listed = rows(output)
        let candidates = listed.map(\.candidate).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        guard let current = command("model", executable: executable)?["id"] as? String,
              listed.contains(where: { $0.id == current }) else { return [] }
        let found = OSAllocatedUnfairLock(initialState: [String: ModelOption]())
        // Bound workers independently of how many families the vendor adds, so
        // catalog refresh cannot flood CLI processes.
        DispatchQueue.concurrentPerform(iterations: min(4, candidates.count)) { worker in
            for index in stride(from: worker, to: candidates.count, by: 4) {
                let candidate = candidates[index]
                let members = listed.filter { $0.candidate == candidate }
                let model = command("model", executable: executable, model: candidate)
                let effort = model == nil ? nil : command("effort", executable: executable, model: candidate)
                let option = family(candidate, rows: members, model: model, effort: effort, current: current)
                found.withLock { $0[candidate] = option }
            }
        }
        let options = found.withLock { $0 }
        guard candidates.allSatisfy({ options[$0] != nil }) else { return [] }
        return candidates.compactMap { options[$0] }
    }

    /// Native resolution, rather than suffix similarity, authorizes grouping.
    /// Missing metadata leaves the catalog unavailable, never a mixed list of
    /// verified families and unverified effort-specific variants.
    static func family(_ candidate: String, rows: [Row], model: [String: Any]?,
                       effort: [String: Any]?, current: String?) -> ModelOption? {
        guard let resolved = model?["id"] as? String, rows.contains(where: { $0.id == resolved }),
              let label = model?["label"] as? String, let tier = model?["effort"] as? String,
              let adjustable = effort?["adjustable"] as? Bool,
              !adjustable || effort?["available"] is [String] else {
            return nil
        }
        let suffix = " (\(tier.capitalized))"
        let title = label.hasSuffix(suffix) ? String(label.dropLast(suffix.count)) : label
        let available = adjustable ? effort?["available"] as? [String] ?? [] : []
        return ModelOption(id: candidate, title: title, efforts: available,
                            isDefault: rows.contains { $0.id == current }, aliases: rows.map(\.id))
    }

    private static func command(_ name: String, executable: String, model: String? = nil) -> [String: Any]? {
        var arguments = ["-p", "/" + name, "--output-format", "json"]
        if let model { arguments += ["--model", model] }
        let (status, output) = ProcessLauncher.capture(executable, arguments, in: NSTemporaryDirectory(),
                                                       timeout: 30, errors: false)
        guard status == 0 else { return nil }
        return payload(output, command: name)
    }

    static func payload(_ output: String, command name: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              value["status"] as? String == "SUCCESS",
              let command = value["command"] as? [String: Any], command["name"] as? String == name else { return nil }
        return command["data"] as? [String: Any]
    }
}

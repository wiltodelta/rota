import Foundation

/// Resolves agy's model before a turn: stream init omits both model and effort.
/// The slash command is read-only, reports zero turns and creates no conversation.
enum AntigravityConfiguration {
    static func read(_ spec: LaunchSpec) -> SessionConfiguration? {
        var arguments = ["-p", "/model", "--output-format", "json"] + spec.modelFlags(effortFlag: "--effort")
        if let resume = spec.resume { arguments += ["--conversation", resume] }
        let (status, output) = ProcessLauncher.capture(spec.executable, arguments, in: spec.workingDirectory,
            timeout: 30, errors: false, environment: spec.environment)
        guard status == 0, let model = AntigravityCatalog.payload(output, command: "model"),
              let id = model["id"] as? String, !id.isEmpty else { return nil }
        let effort = model["effort"] as? String
        let title = (model["label"] as? String).map { ModelOption.title($0, effort: effort ?? "") }
        return SessionConfiguration(model: id, effort: effort, modelTitle: title)
    }
}

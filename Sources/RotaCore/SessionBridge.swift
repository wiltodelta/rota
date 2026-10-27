import Foundation

/// Shared helpers do not inherit a run's environment. Override only an opted-in Rota server, per session.
enum SessionBridge {
    static func codex(_ spec: LaunchSpec) -> [String: Any] {
        guard let command = spec.environment["ROTA_CLI"],
              AgentAccess.isAdded(.codex, executable: spec.executable) else { return [:] }
        var config: [String: Any] = ["mcp_servers.rota.command": command,
                                    "mcp_servers.rota.args": ["mcp"], "mcp_servers.rota.enabled": true]
        for (key, value) in ProcessLauncher.sessionVariables(spec.environment) {
            config["mcp_servers.rota.env." + key] = value
        }
        return config
    }

    static func grok(_ spec: LaunchSpec) -> [[String: Any]] {
        guard let command = spec.environment["ROTA_CLI"],
              AgentAccess.isAdded(.grok, executable: spec.executable) else { return [] }
        let environment = ProcessLauncher.sessionVariables(spec.environment).map { ["name": $0.key, "value": $0.value] }
        return [["name": AgentAccess.serverName, "command": command, "args": ["mcp"], "env": environment]]
    }
}

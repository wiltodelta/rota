import Foundation

/// Ephemeral host integration shared by Claude's terminal and stream runners.
enum ClaudeRunSettings {
    /// Settings Rota adds to the user's for its runs: when Claude waits for the
    /// user in its terminal (a permission or an app it asks to use), the
    /// session is marked needs-reply through the `rota` command the run carries.
    static func hooks(in folder: URL) throws -> URL {
        let command =
            #"[ -n "$ROTA_CLI" ] && "$ROTA_CLI" notify --needs-reply "#
            + #""Claude is waiting for you in its terminal. Open the session in Terminal to answer.""#
        let effortCommand =
            #"if [ -n "$CLAUDE_EFFORT" ] && [ -n "$ROTA_SESSION_EFFORT" ]; then "#
            + #"printf '%s' "$CLAUDE_EFFORT" > "$ROTA_SESSION_EFFORT"; fi"#
        let effortHook: [[String: Any]] = [["hooks": [["type": "command", "command": effortCommand]]]]
        let questionHook: [[String: Any]] = [[
            "type": "command", "command": #"[ -n "$ROTA_CLI" ] && "$ROTA_CLI" question-hook || exit 2"#,
            "timeout": 604800
        ]]
        let settings: [String: Any] = ["hooks": [
            "Notification": [["matcher": "permission_prompt|elicitation_dialog",
                              "hooks": [["type": "command", "command": command]]]],
            "PreToolUse": effortHook + [["matcher": "AskUserQuestion|ExitPlanMode", "hooks": questionHook]],
            "PermissionRequest": [["hooks": questionHook]],
            "Elicitation": [["hooks": questionHook]],
            "Stop": effortHook
        ]]
        let file = folder.appendingPathComponent("claude-settings-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        return file
    }

}

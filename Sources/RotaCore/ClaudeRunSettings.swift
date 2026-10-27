import Foundation

/// Ephemeral host integration shared by Claude's terminal and stream runners.
enum ClaudeRunSettings {
    /// Settings Rota adds to the user's for its runs. When Claude opens a dialog in
    /// its terminal that no other hook answers (an app it asks to use, a paused
    /// session), the `Notification` hook appends Claude's payload to the file the
    /// interactive run names in `ROTA_SESSION_DIALOG`, and the run shows the dialog
    /// in the chat (`ClaudeDialog`). Print mode draws no dialogs and sets no file.
    static func hooks(in folder: URL) throws -> URL {
        let command = #"if [ -n "$ROTA_SESSION_DIALOG" ]; then { cat; echo; } >> "$ROTA_SESSION_DIALOG"; fi"#
        let effortCommand =
            #"if [ -n "$CLAUDE_EFFORT" ] && [ -n "$ROTA_SESSION_EFFORT" ]; then "#
            + #"printf '%s' "$CLAUDE_EFFORT" > "$ROTA_SESSION_EFFORT"; fi"#
        let effortHook: [[String: Any]] = [["hooks": [["type": "command", "command": effortCommand]]]]
        let questionHook: [[String: Any]] = [[
            "type": "command", "command": #"[ -n "$ROTA_CLI" ] && "$ROTA_CLI" question-hook || exit 2"#,
            "timeout": 604800
        ]]
        let settings: [String: Any] = ["hooks": [
            "Notification": [["matcher": ClaudeRunSettings.dialogNotifications,
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

    /// The notification types Claude Code 2.1.311 sends when a dialog opens; a dialog
    /// that names none sends `permission_prompt`. `idle_prompt` is only a finished turn.
    static let dialogNotifications = "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"
}

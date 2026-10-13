import Foundation

/// The bundled helper returns hook JSON even when the session or connection has ended.
public enum ClaudeHookClient {
    public static let timeout: TimeInterval = 86_400

    public static func response(event: String, input: Data, socket: URL?) -> [String: Any] {
        guard let socket, let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              payload["hook_event_name"] as? String == event else {
            return denied(event: event, reason: "Rota could not read the request.")
        }
        do {
            let value = try ControlClient.call("claude-hook", payload, socket: socket, timeout: timeout)
            guard let result = value as? [String: Any] else {
                return denied(event: event, reason: "Rota could not read the answer.")
            }
            return result
        } catch {
            return denied(event: event, reason: "Rota could not receive an answer for this request.")
        }
    }

    static func denied(event: String, reason: String) -> [String: Any] {
        if event == "PreToolUse" {
            return ["hookSpecificOutput": ["hookEventName": event, "permissionDecision": "deny",
                                            "permissionDecisionReason": reason]]
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                        "decision": ["behavior": "deny", "message": reason, "interrupt": true]]]
    }

    static func answer(event: String, params: [String: Any], response: SessionResponse) -> [String: Any] {
        let result = RequestPresentation.claudeResponse(params, response)
        guard result["behavior"] as? String == "allow" else {
            return denied(event: event, reason: "The user declined this request.")
        }
        if event == "PreToolUse" {
            return ["hookSpecificOutput": ["hookEventName": event, "permissionDecision": "allow",
                                            "updatedInput": result["updatedInput"] ?? [:]]]
        }
        // A one-time permission answer never writes rules or changes the permission mode.
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
    }
}

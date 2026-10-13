import Foundation

/// Validates the hook's owning session before projecting its actual tool input into a chat form.
struct ClaudeHookRequest {
    let event: String
    let parameters: [String: Any]
    var request: SessionRequest

    init?(_ payload: [String: Any], session: String) {
        guard payload["session_id"] as? String == session,
              let event = payload["hook_event_name"] as? String,
              let tool = payload["tool_name"] as? String,
              let input = payload["tool_input"] as? [String: Any],
              event == "PermissionRequest" || (event == "PreToolUse" && tool == "AskUserQuestion") else { return nil }
        self.event = event
        var parameters: [String: Any] = ["tool_name": tool, "input": input]
        if let cwd = payload["cwd"] as? String { parameters["cwd"] = cwd }
        self.parameters = parameters
        if tool == "AskUserQuestion" {
            guard let questions = RequestPresentation.claude(parameters) else { return nil }
            request = questions
        } else {
            request = RequestPresentation.permission(title: "Allow " + tool + "?",
                                                     detail: RequestPresentation.detail(parameters))
        }
    }

    func answer(_ response: SessionResponse) -> [String: Any] {
        ClaudeHookClient.answer(event: event, params: parameters, response: response)
    }
}

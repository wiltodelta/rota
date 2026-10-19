import Foundation

/// Translates provider wire requests without asking the model to use a Rota-specific tool.
struct QuestionRequest {
    var question: AgentQuestion
    let response: (QuestionAnswer) -> [String: Any]

    static func choices(_ input: [[String: Any]], codex: Bool) -> [QuestionField] {
        input.enumerated().map { index, field in
            let text = field["question"] as? String ?? "Question"
            let options = (field["options"] as? [[String: Any]] ?? []).map {
                QuestionOption(
                    id: $0["label"] as? String ?? "", label: $0["label"] as? String ?? "",
                    detail: [$0["description"] as? String, $0["preview"] as? String]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
            let kind: QuestionField.Kind
            if field["isSecret"] as? Bool == true {
                kind = .secret
            } else if field["multiSelect"] as? Bool == true || field["multi_select"] as? Bool == true {
                kind = .multiple
            } else {
                kind = options.isEmpty ? .text : .choice
            }
            return QuestionField(
                id: codex ? field["id"] as? String ?? String(index) : text,
                title: text, detail: field["header"] as? String ?? "", kind: kind,
                options: options, allowsOther: !codex || field["isOther"] as? Bool == true)
        }
    }

    static func codex(_ method: String, _ params: [String: Any]) -> QuestionRequest? {
        switch method {
        case "item/tool/requestUserInput", "tool/requestUserInput":
            let question = AgentQuestion(
                title: "Codex needs your reply",
                fields: choices(params["questions"] as? [[String: Any]] ?? [], codex: true))
            return Self(question: question) { answer in
                [
                    "answers": answer.action == "accept"
                        ? answer.values.mapValues { ["answers": $0] } : [:]
                ]
            }
        case "mcpServer/elicitation/request": return elicitation(params)
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            let decisions =
                params["availableDecisions"] as? [Any] ?? ["accept", "acceptForSession", "decline", "cancel"]
            let options = decisions.enumerated().compactMap { index, value -> QuestionOption? in
                if let decision = value as? String, ["decline", "cancel"].contains(decision) { return nil }
                return QuestionOption(id: String(index), label: decisionTitle(value), detail: json(value))
            }
            let question = AgentQuestion(
                title: "Codex requests approval", detail: approvalDetail(params), actions: options, allowsDecline: true)
            return Self(question: question) { answer in
                if ["decline", "cancel"].contains(answer.action) { return ["decision": answer.action] }
                let index = Int(answer.action)
                return ["decision": index.flatMap { decisions.indices.contains($0) ? decisions[$0] : nil } ?? "cancel"]
            }
        case "item/permissions/requestApproval":
            let question = AgentQuestion(
                title: "Codex requests permissions", detail: approvalDetail(params),
                actions: [
                    .init(id: "turn", label: "Allow for This Turn"),
                    .init(id: "session", label: "Allow for This Session"),
                ], allowsDecline: true)
            return Self(question: question) { answer in
                [
                    "permissions": ["turn", "session"].contains(answer.action) ? params["permissions"] ?? [:] : [:],
                    "scope": answer.action == "session" ? "session" : "turn",
                ]
            }
        case "execCommandApproval", "applyPatchApproval": return legacyApproval(params)
        default: return nil
        }
    }

    private static func legacyApproval(_ params: [String: Any]) -> QuestionRequest {
        return Self(
            question: AgentQuestion(
                title: "Codex requests approval", detail: approvalDetail(params),
                actions: [
                    .init(id: "approved", label: "Allow Once"),
                    .init(id: "approved_for_session", label: "Allow for This Session"),
                ], allowsDecline: true)
        ) { answer in
            if ["approved", "approved_for_session"].contains(answer.action) { return ["decision": answer.action] }
            if answer.action == "decline" {
                return ["decision": ["denied": ["rejection": "The user declined."]]]
            }
            return ["decision": "abort"]
        }
    }

    static func claude(_ event: [String: Any]) -> QuestionRequest? {
        let name = event["hook_event_name"] as? String ?? ""
        let input = event["tool_input"] as? [String: Any] ?? [:]
        if name == "Elicitation", let request = elicitation(event) {
            return Self(question: request.question) { answer in
                var output = request.response(answer)
                output["hookEventName"] = "Elicitation"
                return ["hookSpecificOutput": output]
            }
        }
        if name == "PermissionRequest" {
            let tool = event["tool_name"] as? String ?? "Tool"
            let question = AgentQuestion(
                title: "Claude requests approval for " + tool, detail: json(input),
                actions: [.init(id: "accept", label: "Allow Once")], allowsDecline: true)
            return Self(question: question) { answer in
                let decision: [String: Any] =
                    answer.action == "accept"
                    ? ["behavior": "allow", "updatedInput": input]
                    : ["behavior": "deny", "message": "The user declined this request."]
                return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
            }
        }
        let tool = event["tool_name"] as? String ?? ""
        guard ["AskUserQuestion", "ExitPlanMode"].contains(tool) else { return nil }
        let question =
            tool == "AskUserQuestion"
            ? AgentQuestion(
                title: "Claude needs your reply",
                fields: choices(input["questions"] as? [[String: Any]] ?? [], codex: false))
            : AgentQuestion(
                title: "Approve Claude's plan?",
                detail: input["plan"] as? String ?? "Review the plan in the conversation above before approving it.",
                actions: [.init(id: "accept", label: "Approve Plan")])
        return Self(question: question) { answer in
            var output: [String: Any] = ["hookEventName": "PreToolUse"]
            if answer.action == "accept" {
                var updated = input
                if tool == "AskUserQuestion" {
                    updated["answers"] = answer.values.mapValues { $0.joined(separator: ", ") }
                }
                output["permissionDecision"] = "allow"
                output["updatedInput"] = updated
            } else {
                output["permissionDecision"] = "deny"
                output["permissionDecisionReason"] =
                    "The user declined or canceled this request. Do not assume approval."
            }
            return ["hookSpecificOutput": output]
        }
    }

    static func grok(_ method: String, _ params: [String: Any]) -> QuestionRequest? {
        switch method {
        case "_x.ai/ask_user_question", "x.ai/ask_user_question":
            let question = AgentQuestion(
                title: "Grok needs your reply",
                fields: choices(params["questions"] as? [[String: Any]] ?? [], codex: false))
            return Self(question: question) { answer in
                guard answer.action == "accept" else { return ["outcome": "cancelled"] }
                return ["outcome": "accepted", "answers": answer.values]
            }
        case "_x.ai/exit_plan_mode", "x.ai/exit_plan_mode":
            return Self(
                question: AgentQuestion(
                    title: "Approve Grok's plan?",
                    detail: params["planContent"] as? String ?? "",
                    actions: [.init(id: "accept", label: "Approve Plan")])
            ) { answer in
                [
                    "outcome": answer.action == "accept" ? "approved" : "abandoned"
                ]
            }
        case "_x.ai/mcp/elicit", "x.ai/mcp/elicit":
            guard let request = elicitation(params) else { return nil }
            return Self(question: request.question) { answer in
                var response = request.response(answer)
                response["outcome"] = response.removeValue(forKey: "action")
                return response
            }
        case "session/request_permission":
            let options = params["options"] as? [[String: Any]] ?? []
            return Self(
                question: AgentQuestion(
                    title: "Grok requests approval", detail: json(params["toolCall"] ?? [:]),
                    actions: options.compactMap { option in
                        guard let id = option["optionId"] as? String else { return nil }
                        return QuestionOption(id: id, label: option["name"] as? String ?? id)
                    })
            ) { answer in
                if options.contains(where: { $0["optionId"] as? String == answer.action }) {
                    return ["outcome": ["outcome": "selected", "optionId": answer.action]]
                }
                return ["outcome": ["outcome": "cancelled"]]
            }
        default: return nil
        }
    }

    static func elicitation(_ params: [String: Any]) -> QuestionRequest? {
        let mode = params["mode"] as? String ?? "form"
        guard ["form", "url"].contains(mode) else { return nil }
        let schema = params["requestedSchema"] as? [String: Any] ?? params["requested_schema"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let fields = properties.keys.sorted().map { key -> QuestionField in
            let property = properties[key] ?? [:]
            let multiple = property["type"] as? String == "array"
            let source = multiple ? property["items"] as? [String: Any] ?? [:] : property
            let enums = source["enum"] as? [String] ?? []
            let names = source["enumNames"] as? [String] ?? enums
            var options = enums.enumerated().map { index, value in
                QuestionOption(id: value, label: names.indices.contains(index) ? names[index] : value)
            }
            for item in source["oneOf"] as? [[String: Any]] ?? source["anyOf"] as? [[String: Any]] ?? [] {
                if let value = item["const"] as? String {
                    options.append(.init(id: value, label: item["title"] as? String ?? value))
                }
            }
            let type = property["type"] as? String ?? "string"
            let kind: QuestionField.Kind
            if multiple {
                kind = .multiple
            } else if !options.isEmpty {
                kind = .choice
            } else {
                switch type {
                case "boolean": kind = .boolean
                case "integer": kind = .integer
                case "number": kind = .number
                default: kind = .text
                }
            }
            return QuestionField(
                id: key, title: property["title"] as? String ?? key,
                detail: property["description"] as? String ?? "", kind: kind, options: options,
                required: required.contains(key), allowsOther: options.isEmpty, schema: json(property))
        }
        let question = AgentQuestion(
            title: "A tool needs your reply", detail: params["message"] as? String ?? "", fields: fields,
            actions: [.init(id: "accept", label: mode == "url" ? "I've Finished" : "Send Answer")],
            url: params["url"] as? String, allowsDecline: true)
        return Self(question: question) { answer in
            var content: [String: Any] = [:]
            for field in fields { content[field.id] = field.content(answer.values[field.id] ?? []) }
            return ["action": answer.action, "content": answer.action == "accept" ? content : NSNull()]
        }
    }

    private static func approvalDetail(_ params: [String: Any]) -> String {
        var parts: [String] = []
        if let reason = params["reason"] as? String { parts.append(reason) }
        if let command = params["command"] as? String {
            parts.append(command)
        } else if let command = params["command"] as? [String] {
            parts.append(command.map(shellQuote).joined(separator: " "))
        }
        if let folder = params["cwd"] as? String { parts.append("Folder: " + folder) }
        if let root = params["grantRoot"] as? String { parts.append("Write access: " + root) }
        for (key, label) in [
            ("fileChanges", "File changes"), ("permissions", "Requested permissions"),
            ("additionalPermissions", "Additional permissions"),
            ("networkApprovalContext", "Network access"),
        ] {
            if let value = params[key], !(value is NSNull) { parts.append(label + ":\n" + json(value)) }
        }
        return parts.joined(separator: "\n\n")
    }

    static func json(_ value: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        else { return "" }
        return lossyUTF8(data)
    }

    private static func decisionTitle(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            if let amendment = object["acceptWithExecpolicyAmendment"] as? [String: Any],
                let command = amendment["execpolicy_amendment"] as? [String] {
                return "Always Allow: " + command.map(shellQuote).joined(separator: " ")
            }
            if let amendment = object["applyNetworkPolicyAmendment"] as? [String: Any],
                let policy = amendment["network_policy_amendment"] as? [String: Any],
                let host = policy["host"] as? String {
                return (policy["action"] as? String == "deny" ? "Always Deny: " : "Always Allow: ") + host
            }
        }
        switch value as? String {
        case "accept": return "Allow Once"
        case "acceptForSession": return "Allow for This Session"
        case "decline": return "Decline"
        case "cancel": return "Cancel"
        default: return "Apply Proposed Rule"
        }
    }
}

import Foundation

extension QuestionRequest {
    static func elicitation(_ params: [String: Any]) -> QuestionRequest? {
        let mode = params["mode"] as? String ?? "form"
        if mode == "openai/userVerification" { return deviceVerification(params) }
        guard ["form", "openai/form", "openaiForm", "url"].contains(mode) else { return nil }
        let schema = params["requestedSchema"] as? [String: Any] ?? params["requested_schema"] as? [String: Any] ?? [:]
        if mode != "url", !supportsForm(schema) {
            return unsupportedForm(params)
        }
        let fields = elicitationFields(schema)
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

    private static func elicitationFields(_ schema: [String: Any]) -> [QuestionField] {
        let required = schema["required"] as? [String] ?? []
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        return properties.keys.sorted().map { key -> QuestionField in
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
            if type == "string", property["writeOnly"] as? Bool == true || property["format"] as? String == "password" {
                kind = .secret
            } else if multiple {
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
    }

    private static func supportsForm(_ schema: [String: Any]) -> Bool {
        guard schema["type"] == nil || schema["type"] as? String == "object",
              schema["oneOf"] == nil, schema["anyOf"] == nil, schema["$ref"] == nil else { return false }
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        for property in properties.values {
            guard let type = property["type"] as? String,
                  ["string", "number", "integer", "boolean", "array"].contains(type),
                  property["$ref"] == nil else { return false }
            if type == "array" {
                guard let items = property["items"] as? [String: Any],
                      items["enum"] is [String] || items["anyOf"] is [[String: Any]]
                else { return false }
            }
        }
        return true
    }

    private static func unsupportedForm(_ params: [String: Any]) -> QuestionRequest {
        Self(question: AgentQuestion(
            title: "This form needs the provider's app",
            detail: (params["message"] as? String ?? "")
                + "\n\nThis form uses a schema Rota cannot display. Cancel here and continue in the provider's app.",
            actions: [], allowsDecline: true
        )) { answer in ["action": answer.action == "decline" ? "decline" : "cancel"] }
    }

    private static func deviceVerification(_ params: [String: Any]) -> QuestionRequest {
        Self(question: AgentQuestion(
            title: params["title"] as? String ?? "Device verification required",
            detail: (params["description"] as? String ?? "")
                + "\n\nThis request requires device verification in the provider's app. "
                + "Rota cannot produce the required proof. Cancel here and continue in the provider's app.",
            actions: [], allowsDecline: true
        )) { answer in ["action": answer.action == "decline" ? "decline" : "cancel"] }
    }
}

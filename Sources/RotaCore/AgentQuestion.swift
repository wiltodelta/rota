import Foundation

/// A provider request that remains pending until the user explicitly answers it.
public struct AgentQuestion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var fields: [QuestionField]
    public var actions: [QuestionOption]
    public var url: String?
    public var allowsDecline: Bool?
    /// Async message questions receive a user message, not a reply to a suspended RPC.
    public var replyViaMessage: Bool?

    public init(
        id: String = UUID().uuidString, title: String, detail: String = "",
        fields: [QuestionField] = [], actions: [QuestionOption] = [.init(id: "accept", label: "Send Answer")],
        url: String? = nil, allowsDecline: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.fields = fields
        self.actions = actions
        self.url = url
        self.allowsDecline = allowsDecline
    }
}

public struct QuestionOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var detail: String
    public init(id: String, label: String, detail: String = "") {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct QuestionField: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, secret, boolean, number, integer, choice, multiple }
    public var id: String
    public var title: String
    public var detail: String = ""
    public var kind: Kind = .text
    public var options: [QuestionOption] = []
    public var required = true
    public var allowsOther = true
    /// The original primitive MCP schema, for validation without dropping constraints.
    public var schema: String?

    public init(
        id: String, title: String, detail: String = "", kind: Kind = .text,
        options: [QuestionOption] = [], required: Bool = true, allowsOther: Bool = true, schema: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.options = options
        self.required = required
        self.allowsOther = allowsOther
        self.schema = schema
    }
}

public struct QuestionAnswer: Codable, Equatable, Sendable {
    public var action: String
    public var values: [String: [String]]
    public init(action: String = "accept", values: [String: [String]] = [:]) {
        self.action = action
        self.values = values
    }
}

extension AgentQuestion {
    /// Validates at the scheduler boundary as well as in the view. No default is consent.
    public func validate(_ answer: QuestionAnswer) throws {
        if answer.action == "cancel" || answer.action == "decline" { return }
        guard actions.contains(where: { $0.id == answer.action }) else { throw ControlError("Choose an answer.") }
        for field in fields {
            let values = answer.values[field.id] ?? []
            if values.isEmpty || values.allSatisfy({ $0.isEmpty }) {
                if field.required { throw ControlError("Answer \(field.title).") }
                continue
            }
            if field.kind != .multiple, values.count != 1 {
                throw ControlError("Choose one answer for \(field.title).")
            }
            if !field.allowsOther, !field.options.isEmpty,
                values.contains(where: { value in !field.options.contains { $0.id == value } }) {
                throw ControlError("Choose a listed answer for \(field.title).")
            }
            try field.validate(values)
        }
    }

    public func validationMessage(_ answer: QuestionAnswer) -> String? {
        do {
            try validate(answer)
            return nil
        } catch { return error.localizedDescription }
    }
}

extension QuestionField {
    func validate(_ values: [String]) throws {
        let constraints =
            schema.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func invalid() -> ControlError { ControlError("Check the value for \(title).") }
        for value in values {
            switch kind {
            case .boolean:
                guard ["true", "false"].contains(value) else { throw invalid() }
            case .number, .integer:
                try validateNumber(value, constraints: constraints)
            default:
                if let minimum = constraints["minLength"] as? Int, value.unicodeScalars.count < minimum {
                    throw invalid()
                }
                if let maximum = constraints["maxLength"] as? Int, value.unicodeScalars.count > maximum {
                    throw invalid()
                }
            }
        }
        if let minimum = constraints["minItems"] as? Int, values.count < minimum { throw invalid() }
        if let maximum = constraints["maxItems"] as? Int, values.count > maximum { throw invalid() }
    }

    private func validateNumber(_ value: String, constraints: [String: Any]) throws {
        let error = ControlError("Check the value for \(title).")
        guard let number = Double(value), number.isFinite,
            kind != .integer || number.rounded() == number
        else { throw error }
        if kind == .integer {
            try validateInteger(value, constraints: constraints)
        } else {
            if let minimum = constraints["minimum"] as? Double, number < minimum { throw error }
            if let maximum = constraints["maximum"] as? Double, number > maximum { throw error }
        }
    }

    private func validateInteger(_ value: String, constraints: [String: Any]) throws {
        let error = ControlError("Check the value for \(title).")
        var decimal = NSDecimalNumber(string: value).decimalValue
        guard !decimal.isNaN else { throw error }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .plain)
        guard decimal == rounded else { throw error }
        if let minimum = constraints["minimum"] as? NSNumber, decimal < minimum.decimalValue { throw error }
        if let maximum = constraints["maximum"] as? NSNumber, decimal > maximum.decimalValue { throw error }
    }

    func content(_ values: [String]) -> Any? {
        guard let value = values.first else { return nil }
        switch kind {
        case .boolean: return value == "true"
        case .integer: return NSDecimalNumber(string: value)
        case .number: return Double(value)
        case .multiple: return values
        default: return value
        }
    }
}

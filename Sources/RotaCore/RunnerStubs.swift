import Foundation

/// Placeholder launch descriptor retained for `RoutineLaunching` test conformances;
/// real process launches run inside `rota-core`.
public struct LaunchSpec: Sendable {
    public init() {}
}

public protocol RunControl: Sendable {
    func stop()
    func send(_ message: String)
    var attachCommand: [String]? { get }
}

public extension RunControl {
    func send(_ message: String) {}
    var attachCommand: [String]? { nil }
}

public struct RunEvents: Sendable {
    public var session: @Sendable (String) -> Void
    public var finished: @Sendable (RunOutcome) -> Void

    public init(
        session: @escaping @Sendable (String) -> Void,
        finished: @escaping @Sendable (RunOutcome) -> Void
    ) {
        self.session = session
        self.finished = finished
    }
}

public protocol RoutineLaunching: Sendable {
    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl
}

/// Marker type selecting the Rust `AgentLauncher` in production `Scheduler` instances.
public final class ProcessLauncher: RoutineLaunching, Sendable {
    public init() {}

    public func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        struct UnreachableControl: RunControl {
            func stop() {}
        }
        return UnreachableControl()
    }
}

public func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

enum QuestionRequest {
    static func json(_ value: Any) -> String {
        let options: JSONSerialization.WritingOptions = [
            .prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else {
            return ""
        }
        return lossyUTF8(data)
    }
}

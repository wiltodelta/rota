import Foundation

public enum RunTrigger: String, Codable, Sendable {
    case scheduled
    /// A slot missed while the Mac slept or Rota was closed, run late once.
    case catchUp
    case manual
}

public enum RunOutcome: Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed(exitCode: Int32)
    case timedOut
    case cancelled
    /// The app quit or crashed while the run was in flight.
    case interrupted
    case launchFailed(String)
    case skipped(String)

    public var title: String {
        switch self {
        case .running: return "Running"
        case .succeeded: return "Completed"
        case .failed(let code): return "Failed (exit \(code))"
        case .timedOut: return "Timed out"
        case .cancelled: return "Stopped"
        case .interrupted: return "Interrupted"
        case .launchFailed(let reason): return "Could not start: \(reason)"
        case .skipped(let reason): return "Skipped: \(reason)"
        }
    }

    /// Worth a notification: the routine did not do its work and nobody stopped it on purpose.
    public var isFailure: Bool {
        switch self {
        case .failed, .timedOut, .interrupted, .launchFailed, .skipped: return true
        case .running, .succeeded, .cancelled: return false
        }
    }
}

public enum TerminalState: String, Codable, Sendable {
    case waiting
    case working
}

public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var routineID: String
    public var trigger: RunTrigger
    public var harness: Harness
    /// Explicit model and effort requested when this session started; absent in old records or for CLI defaults.
    public var model: String?
    public var effort: String?
    /// The session configuration reported by the harness, rather than a current CLI default.
    public var reportedModel: String?
    public var reportedEffort: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: RunOutcome
    public var logPath: String?
    /// The harness session, for harnesses whose runs can be reopened to chat.
    public var sessionID: String?
    /// When the user last looked at the session; it is unread if it ended after that.
    public var readAt: Date?
    /// What the session asked the user through `rota notify --needs-reply`, until
    /// the user answers in its chat or dismisses it.
    public var attention: String?
    public var questions: [AgentQuestion]?
    /// A suspended provider must receive its RPC reply before async answers can steer the session.
    public var nextQuestion: AgentQuestion? {
        questions?.first { $0.replyViaMessage != true } ?? questions?.first
    }

    /// How many times Rota continued this session on its own after the Mac slept
    /// or shut down in the middle of it (`Scheduler.resumeLimit` at most).
    public var resumes: Int?
    /// Present for terminal-owned continuations, including interrupted ones.
    public var terminalState: TerminalState?

    public var statusTitle: String {
        guard outcome == .running, let terminalState else { return outcome.title }
        return terminalState == .working ? "Working in Terminal" : "Waiting in Terminal"
    }

    /// A slot that did not run: a note in the routine's history, not a session.
    public var isSkip: Bool {
        if case .skipped = outcome { return true }
        return false
    }

    /// Finished since the user last opened it, so the sidebar marks it.
    public var isUnread: Bool {
        guard outcome != .running, !isSkip, let endedAt else { return false }
        return readAt.map { $0 < endedAt } ?? true
    }

    public init(id: UUID = UUID(), routineID: String, trigger: RunTrigger, harness: Harness,
                startedAt: Date, endedAt: Date? = nil, outcome: RunOutcome, logPath: String? = nil) {
        self.id = id
        self.routineID = routineID
        self.trigger = trigger
        self.harness = harness
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.logPath = logPath
    }
}

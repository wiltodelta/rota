import Foundation
import os

/// A Codex routine run on the shared local app-server daemon, so the user can
/// steer the turn from Rota while it works (`turn/steer`) and resume the thread
/// in Codex afterwards. Protocol: `codex app-server generate-json-schema`.
final class CodexDaemonRun: RunControl, @unchecked Sendable {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "codex")

    private let spec: LaunchSpec
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.codex")
    private var proxy: Process?
    private var peer: JSONRPCPeer?
    private var threadID: String?
    private var turnID: String?
    private var stopReason: RunOutcome?

    private init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) -> CodexDaemonRun {
        let run = CodexDaemonRun(spec: spec, journal: journal)
        run.queue.async { run.connect() }
        return run
    }

    func stop() {
        queue.async { self.interrupt(as: .cancelled) }
    }

    func send(_ message: String) {
        queue.async {
            guard let threadID = self.threadID, let turnID = self.turnID, !self.journal.isFinished else { return }
            self.journal.line(Transcript.userLines(message))
            self.peer?.request("turn/steer", ["threadId": threadID, "expectedTurnId": turnID,
                                              "input": [["type": "text", "text": message]]]) { result in
                if case .failure(let error) = result {
                    self.journal.line("[rota: message not delivered: \(error.message)]")
                }
            }
        }
    }

    // MARK: On `queue`

    private func connect() {
        let (status, output) = ProcessLauncher.capture(spec.executable, ["app-server", "daemon", "start"],
                                                       in: spec.workingDirectory)
        guard status == 0 else {
            return journal.finish(.launchFailed("codex app-server daemon start: \(output.prefix(200))"))
        }
        let process = ProcessLauncher.loginShellProcess(spec.executable, ["app-server", "proxy"],
                                                        in: spec.workingDirectory, environment: spec.environment)
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return journal.finish(.launchFailed(error.localizedDescription))
        }
        proxy = process
        let peer = JSONRPCPeer(transport: WebSocketTransport(input: stdin.fileHandleForWriting,
                                                             output: stdout.fileHandleForReading))
        peer.onNotification = { [weak self] method, params in self?.queue.async { self?.handle(method, params) } }
        peer.onClose = { [weak self] in self?.queue.async { self?.journal.finish(.interrupted) } }
        self.peer = peer
        peer.request("initialize", ["clientInfo": ["name": "rota", "version": "1"]]) { [weak self] result in
            self?.queue.async { self?.initialized(result) }
        }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.interrupt(as: .timedOut) }
        }
    }

    private func initialized(_ result: Result<Any, JSONRPCError>) {
        guard case .success = result else { return fail(result, "initialize") }
        peer?.notify("initialized")
        var params: [String: Any] = ["cwd": spec.workingDirectory, "approvalPolicy": "never",
                                     "sandbox": "danger-full-access"]
        if let model = spec.model { params["model"] = model }
        // A continued session loads its thread back onto the daemon and takes the next turn.
        let method = spec.resume == nil ? "thread/start" : "thread/resume"
        if let thread = spec.resume { params["threadId"] = thread }
        peer?.request(method, params) { [weak self] result in
            self?.queue.async { self?.threadStarted(result) }
        }
    }

    private func threadStarted(_ result: Result<Any, JSONRPCError>) {
        guard case .success(let value) = result,
              let thread = (value as? [String: Any])?["thread"] as? [String: Any],
              let id = thread["id"] as? String else {
            return fail(result, spec.resume == nil ? "thread/start" : "thread/resume")
        }
        threadID = id
        // The header names the model the daemon picked, so a chosen one can be checked.
        let model = (value as? [String: Any])?["model"] as? String
        if spec.resume == nil { journal.line("[codex thread \(id)" + (model.map { ", \($0)" } ?? "") + "]") }
        journal.session(id)
        var params: [String: Any] = ["threadId": id, "input": [["type": "text", "text": spec.prompt]]]
        if let model = spec.model { params["model"] = model }
        if let effort = spec.effort { params["effort"] = effort }
        peer?.request("turn/start", params) { [weak self] result in
            self?.queue.async {
                guard case .success(let value) = result,
                      let turn = (value as? [String: Any])?["turn"] as? [String: Any] else {
                    return self?.fail(result, "turn/start") ?? ()
                }
                self?.turnID = turn["id"] as? String
            }
        }
    }

    private func handle(_ method: String, _ params: [String: Any]) {
        switch method {
        case "item/started":
            if let line = Self.describe(started: params["item"] as? [String: Any]) { journal.line(line) }
        case "item/completed":
            let item = params["item"] as? [String: Any]
            if item?["type"] as? String == "agentMessage", let text = item?["text"] as? String { journal.line(text) }
        case "turn/completed":
            turnCompleted(params["turn"] as? [String: Any])
        default:
            break
        }
    }

    private func turnCompleted(_ turn: [String: Any]?) {
        guard turn?["id"] as? String == turnID || turnID == nil else { return }
        let outcome: RunOutcome
        switch turn?["status"] as? String {
        case "completed": outcome = .succeeded
        case "interrupted": outcome = stopReason ?? .cancelled
        default: outcome = .failed(exitCode: 1)
        }
        if let error = (turn?["error"] as? [String: Any])?["message"] as? String { journal.line("[error] \(error)") }
        journal.finish(outcome)
        disconnect()
    }

    static func describe(started item: [String: Any]?) -> String? {
        switch item?["type"] as? String {
        case "commandExecution": return (item?["command"] as? String).map { "-> $ \($0)" }
        case "mcpToolCall": return (item?["tool"] as? String).map { "-> \($0)" }
        case "dynamicToolCall": return (item?["tool"] as? String).map { "-> \($0)" }
        case "fileChange": return "-> edit files"
        case "webSearch": return (item?["query"] as? String).map { "-> search \($0)" }
        default: return nil
        }
    }

    private func interrupt(as reason: RunOutcome) {
        guard !journal.isFinished else { return }
        stopReason = reason
        guard let threadID, let turnID else {
            journal.finish(reason)
            return disconnect()
        }
        peer?.request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) { _ in }
        // If the daemon never confirms, end the run anyway.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.journal.finish(reason)
            self?.disconnect()
        }
    }

    private func fail(_ result: Result<Any, JSONRPCError>, _ step: String) {
        if case .failure(let error) = result { journal.finish(.launchFailed("\(step): \(error.message)")) }
        disconnect()
    }

    private func disconnect() {
        peer?.close()
        proxy?.terminate()
    }
}

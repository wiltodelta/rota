import Foundation

/// A Grok routine run through the shared leader over ACP (`grok agent --leader
/// stdio`), so messages from Rota join the live session. Protocol:
/// ~/.grok/docs/user-guide/15-agent-mode.md.
final class GrokACPRun: RunControl, @unchecked Sendable {
    private let spec: LaunchSpec
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.grok")
    private var process: Process?
    private var peer: JSONRPCPeer?
    private var sessionID: String?
    private var stopReason: RunOutcome?
    /// Prompts still waiting for their turn to end. Grok queues a message sent
    /// mid-turn after the current turn, so the run ends only when all are answered.
    private var openPrompts = 0
    private var routineOutcome: RunOutcome?
    /// True while `session/load` replays history, which must not reach the log again.
    private var loading = false

    private init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) -> GrokACPRun {
        let run = GrokACPRun(spec: spec, journal: journal)
        run.queue.async { run.connect() }
        return run
    }

    func stop() {
        queue.async { self.cancel(as: .cancelled) }
    }

    func send(_ message: String) {
        queue.async {
            guard let sessionID = self.sessionID, !self.journal.isFinished else { return }
            self.journal.line(Transcript.userLines(message))
            self.openPrompts += 1
            let params: [String: Any] = ["sessionId": sessionID, "prompt": [["type": "text", "text": message]]]
            self.peer?.request("session/prompt", params) { result in
                self.queue.async { self.promptEnded(result, isRoutine: false) }
            }
        }
    }

    // MARK: On `queue`

    private func connect() {
        // On the command line, not session/set_config_option: Grok's guide says a
        // model set that way is synced to the leader's other clients.
        let arguments = ["agent", "--leader", "--always-approve"]
            + spec.modelFlags(effortFlag: "--reasoning-effort") + ["stdio"]
        let process = ProcessLauncher.loginShellProcess(spec.executable, arguments,
                                                        in: ProcessLauncher.helperDirectory, environment: [:])
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
        self.process = process
        let peer = JSONRPCPeer(transport: LineTransport(input: stdin.fileHandleForWriting,
                                                        output: stdout.fileHandleForReading))
        peer.onNotification = { [weak self] method, params in self?.queue.async { self?.handle(method, params) } }
        peer.onRequest = { method, params in Self.answer(method, params) }
        peer.onClose = { [weak self] in self?.queue.async { self?.journal.finish(.interrupted) } }
        self.peer = peer
        let hello: [String: Any] = ["protocolVersion": 1, "clientCapabilities": [String: Any]()]
        peer.request("initialize", hello) { [weak self] result in
            self?.queue.async { self?.initialized(result) }
        }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.cancel(as: .timedOut) }
        }
    }

    /// The rule that tells a Grok session its Rota session and how to notify the user from it.
    static func sessionRule(_ environment: [String: String]) -> String? {
        let variables = ProcessLauncher.sessionVariables(environment)
        guard let session = variables["ROTA_SESSION"], let routine = variables["ROTA_ROUTINE"] else { return nil }
        var rule = "This session is a run of the Rota routine \(routine), Rota session \(session). "
            + "The environment variables ROTA_SESSION, ROTA_ROUTINE and ROTA_CLI are not set in your commands"
        if let cli = variables["ROTA_CLI"] {
            rule += "; to show the user a Mac notification that opens this session, run "
                + "'\(cli)' notify --session \(session) \"message\", adding --needs-reply when they must answer "
                + "or confirm something"
        }
        return rule + "."
    }

    private func initialized(_ result: Result<Any, JSONRPCError>) {
        guard case .success = result else { return fail(result, "initialize") }
        var params: [String: Any] = ["cwd": spec.workingDirectory, "mcpServers": [Any]()]
        // Grok's commands run under its shared leader, which has no per-session
        // environment; the session learns who it is from a rule instead.
        if let rule = Self.sessionRule(spec.environment) { params["_meta"] = ["rules": rule] }
        if let session = spec.resume {
            // Loading replays the session as updates; they are already in the log.
            params["sessionId"] = session
            loading = true
            peer?.request("session/load", params) { [weak self] result in
                self?.queue.async {
                    self?.loading = false
                    guard case .success = result else { return self?.fail(result, "session/load") ?? () }
                    self?.sessionReady(session)
                }
            }
        } else {
            peer?.request("session/new", params) { [weak self] result in
                self?.queue.async { self?.sessionCreated(result) }
            }
        }
    }

    private func sessionCreated(_ result: Result<Any, JSONRPCError>) {
        guard case .success(let value) = result, let id = (value as? [String: Any])?["sessionId"] as? String else {
            return fail(result, "session/new")
        }
        let options = (value as? [String: Any])?["configOptions"] as? [[String: Any]] ?? []
        let model = options.first { $0["id"] as? String == "model" }?["currentValue"] as? String
        journal.line("[grok session \(id)" + (model.map { ", \($0)" } ?? "") + "]")
        sessionReady(id)
    }

    private func sessionReady(_ id: String) {
        sessionID = id
        journal.session(id)
        let params: [String: Any] = ["sessionId": id, "prompt": [["type": "text", "text": spec.prompt]]]
        openPrompts += 1
        peer?.request("session/prompt", params) { [weak self] result in
            self?.queue.async { self?.promptEnded(result, isRoutine: true) }
        }
    }

    /// The routine's own prompt decides the outcome; the run ends when no prompt is left open.
    private func promptEnded(_ result: Result<Any, JSONRPCError>, isRoutine: Bool) {
        openPrompts -= 1
        journal.endText()
        let outcome: RunOutcome
        switch result {
        case .success(let value):
            let reason = (value as? [String: Any])?["stopReason"] as? String
            outcome = reason == "cancelled" ? (stopReason ?? .cancelled) : .succeeded
        case .failure(let error):
            journal.line("[error] \(error.message)")
            outcome = stopReason ?? .failed(exitCode: 1)
        }
        if isRoutine { routineOutcome = outcome }
        guard openPrompts <= 0, let routineOutcome else { return }
        journal.finish(routineOutcome)
        disconnect()
    }

    private func handle(_ method: String, _ params: [String: Any]) {
        guard method == "session/update", !loading, let update = params["update"] as? [String: Any] else { return }
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            if let text = (update["content"] as? [String: Any])?["text"] as? String { journal.text(text) }
        case "tool_call":
            journal.line("-> \(update["title"] as? String ?? "tool")")
        case "plan":
            let steps = (update["entries"] as? [[String: Any]] ?? []).map {
                PlanStep(status: $0["status"] as? String, text: $0["content"] as? String ?? "")
            }
            if !steps.isEmpty { journal.line(PlanStep.lines(steps)) }
        default:
            break
        }
    }

    /// Permission requests (rare with --always-approve) get the first "allow"
    /// option; Rota offers no file system or terminal of its own.
    static func answer(_ method: String, _ params: [String: Any]) -> Any? {
        guard method == "session/request_permission",
              let options = params["options"] as? [[String: Any]],
              let allow = options.first(where: { ($0["kind"] as? String)?.hasPrefix("allow") == true }),
              let optionID = allow["optionId"] else { return nil }
        return ["outcome": ["outcome": "selected", "optionId": optionID]]
    }

    private func cancel(as reason: RunOutcome) {
        guard !journal.isFinished else { return }
        stopReason = reason
        if let sessionID { peer?.notify("session/cancel", ["sessionId": sessionID]) }
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
        process?.terminate()
    }
}

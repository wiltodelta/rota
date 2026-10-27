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
    /// Messages sent before the session exists, prompted once it is ready.
    private var early: [String] = []
    /// Grok's own work after the prompts return: background tasks and the turns their completion wakes.
    private var activity = GrokActivity()
    private var applied = SessionConfiguration()
    private var effortOptions: [String] = []

    private init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal

    }

    static func start(_ spec: LaunchSpec, journal: RunJournal,
                      transport: MessageTransport? = nil) -> GrokACPRun {
        let run = GrokACPRun(spec: spec, journal: journal)
        let injected = UncheckedSendable(transport)
        run.queue.async {
            run.restoreActivity()
            if let transport = injected.value { run.connect(transport: transport) } else { run.connect() }
        }
        return run
    }

    private func restoreActivity() {
        if let session = self.spec.resume {
            let restored = GrokRecovery(session: session)
            activity = restored.activity
            if spec.adopt { routineOutcome = restored.outcome }
        }
    }

    func stop() {
        queue.async { self.cancel(as: .cancelled) }
    }

    func send(_ message: String) {
        queue.async {
            guard !self.journal.isFinished else { return self.journal.undelivered(message) }
            self.journal.record(.user, message)
            guard let sessionID = self.sessionID, !self.loading else { return self.early.append(message) }
            self.prompt(message, in: sessionID)
        }
    }

    private func prompt(_ message: String, in sessionID: String) {
        openPrompts += 1
        let params: [String: Any] = ["sessionId": sessionID, "prompt": HarnessInput.blocks(message, for: .grokACP)]
        peer?.request("session/prompt", params) { result in
            self.promptEnded(result)
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
        connect(transport: LineTransport(input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading))
    }

    private func connect(transport: MessageTransport) {
        let peer = JSONRPCPeer(transport: transport, callbackQueue: queue)
        peer.onNotification = { [weak self] method, params in self?.handle(method, params) }
        peer.onRequestAsync = { [weak self] id, method, params, reply in
            guard let self, params["sessionId"] as? String == self.sessionID else {
                self?.peer?.dismissRequest(id)
                return
            }
            // Retain the configured automatic tool permissions; explicit questions never auto-answer.
            if method == "session/request_permission", let result = Self.answer(method, params) { return reply(result) }
            guard var request = QuestionRequest.grok(method, params) else { return reply(nil) }
            request.question.id = id
            let boxed = UncheckedSendable((request, reply))
            self.journal.ask(request.question) { answer in
                self.queue.async { boxed.value.1(boxed.value.0.response(answer)) }
            }
        }
        peer.onClose = { [weak self] in self?.connectionLost() }
        self.peer = peer
        let hello: [String: Any] = ["protocolVersion": 1, "clientCapabilities": [String: Any]()]
        peer.request("initialize", hello) { [weak self] result in
            self?.initialized(result)
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
        guard !journal.isFinished else { return }
        guard case .success(let value) = result else { return fail(result, "initialize") }
        let agent = (value as? [String: Any])?["agentInfo"] as? [String: Any]
        let metadata = (value as? [String: Any])?["_meta"] as? [String: Any]
        journal.provenance(server: agent?["version"] as? String ?? metadata?["agentVersion"] as? String)
        let directory = spec.resume.flatMap { NativeTranscript.locate(.grok, session: $0) }
            .flatMap(NativeTranscript.grokDirectory) ?? spec.workingDirectory
        var params: [String: Any] = ["cwd": directory, "mcpServers": SessionBridge.grok(spec)]
        // Grok's commands run under its shared leader, which has no per-session
        // environment; the session learns who it is from a rule instead.
        if let rule = Self.sessionRule(spec.environment) { params["_meta"] = ["rules": rule] }
        if let session = spec.resume {
            // Loading replays the session as updates; they are already in the log.
            params["sessionId"] = session
            sessionID = session
            loading = true
            peer?.request("session/load", params) { [weak self] result in
                self?.loading = false
                guard case .success(let value) = result else { return self?.fail(result, "session/load") ?? () }
                self?.configure(value)
                if self?.spec.adopt == true {
                    self?.restored(value, session: session)
                } else {
                    self?.sessionReady(session)
                }
            }
        } else {
            peer?.request("session/new", params) { [weak self] result in
                self?.sessionCreated(result)
            }
        }
    }

    private func sessionCreated(_ result: Result<Any, JSONRPCError>) {
        guard case .success(let value) = result, let id = (value as? [String: Any])?["sessionId"] as? String else {
            return fail(result, "session/new")
        }
        let configuration = configure(value)
        if let requested = spec.model, configuration.model != requested {
            journal.finish(.launchFailed("Grok did not apply the requested model."))
            return disconnect()
        }
        journal.line("[grok session \(id)" + (configuration.model.map { ", \($0)" } ?? "") + "]")
        sessionReady(id)
    }

    private func restored(_ value: Any, session: String) {
        let metadata = (value as? [String: Any])?["_meta"] as? [String: Any]
        if let running = metadata?["x.ai/runningPromptId"] as? String {
            activity.adoptRunning(running)
            routineOutcome = nil
        }
        journal.session(session)
        if stopReason != nil, !activity.idle { peer?.notify("session/cancel", ["sessionId": session]) }
        for message in early { prompt(message, in: session) }
        early = []
        if activity.idle, openPrompts == 0 {
            journal.finish(stopReason ?? routineOutcome ?? .interrupted)
            disconnect()
        } else {
            finishIfIdle()
        }
    }

    @discardableResult
    private func configure(_ value: Any) -> SessionConfiguration {
        let configuration = SessionConfiguration.acp(value)
        if configuration.model != nil { applied.model = configuration.model }
        if configuration.effort != nil { applied.effort = configuration.effort }
        let options = (value as? [String: Any])?["configOptions"] as? [[String: Any]] ?? []
        if let effort = options.first(where: { $0["id"] as? String == "reasoning_effort" }) {
            effortOptions = (effort["options"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
        }
        journal.configure(configuration)
        return configuration
    }

    private func sessionReady(_ id: String) {
        sessionID = id
        journal.session(id)
        if let requested = spec.model, applied.model != requested {
            journal.finish(.launchFailed("Grok did not apply the requested model."))
            return disconnect()
        }
        guard let effort = spec.effort else { return beginPrompt(id) }
        guard effortOptions.contains(effort) else {
            journal.finish(.launchFailed("Grok does not advertise the requested effort for this model."))
            return disconnect()
        }
        // The shared leader can ignore the proxy's effort flag. Apply it to this session only.
        peer?.request("session/set_config_option", ["sessionId": id, "configId": "reasoning_effort",
                                                    "value": effort]) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result else { return self.fail(result, "session/set_config_option") }
            let applied = self.configure(value)
            guard applied.effort == effort else {
                self.journal.finish(.launchFailed("Grok did not apply the requested effort level."))
                return self.disconnect()
            }
            self.beginPrompt(id)
        }
    }

    private func beginPrompt(_ id: String) {
        guard !journal.isFinished, stopReason == nil else { return }
        prompt(spec.prompt, in: id)
        // Grok queues each after the routine's prompt, as it does a message sent mid-turn.
        for message in early { prompt(message, in: id) }
        early = []
    }

    /// The routine's own prompt decides the outcome; the run ends when no prompt is left open.
    private func promptEnded(_ result: Result<Any, JSONRPCError>) {
        openPrompts -= 1
        journal.endText()
        let outcome: RunOutcome
        switch result {
        case .success(let value):
            outcome = stopReason ?? GrokRecovery.outcome((value as? [String: Any])?["stopReason"] as? String)
        case .failure(let error):
            if error.message == "connection closed" { journal.requireReconciliation() }
            journal.line("[error] \(error.message)")
            outcome = stopReason ?? .failed(exitCode: 1)
        }
        if routineOutcome == nil || outcome != .succeeded { routineOutcome = outcome }
        if openPrompts <= 0, outcome == .succeeded, stopReason == nil, activity.running > 0 {
            journal.record(.status, TranscriptService.waiting(activity.running))
        }
        finishIfIdle()
    }

    /// The run ends once every prompt has returned and Grok has no work left that will wake the session.
    private func finishIfIdle() {
        guard openPrompts <= 0, let routineOutcome, !journal.isFinished else { return }
        guard routineOutcome != .succeeded || stopReason != nil || activity.idle else { return }
        journal.finish(stopReason ?? routineOutcome)
        disconnect()
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
        if sessionID == nil, spec.resume == nil {
            journal.finish(reason)
            return disconnect()
        }
        if let sessionID { peer?.notify("session/cancel", ["sessionId": sessionID]) }
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.journal.isFinished else { return }
            self.journal.record(.status, "Grok has not confirmed cancellation; waiting for the native session")
            self.cancel(as: reason)
        }
    }

    private func fail(_ result: Result<Any, JSONRPCError>, _ step: String) {
        guard !journal.isFinished else { return }
        if case .failure(let error) = result {
            let absent = step == "session/load" && error.serverCode == "FS_NOT_FOUND"
                && spec.resume.flatMap { NativeTranscript.locate(.grok, session: $0) } == nil
                && FileManager.default.fileExists(atPath: spec.workingDirectory)
            if spec.resume != nil, !absent { journal.requireReconciliation() }
            journal.finish(.launchFailed("\(step): \(error.message)"))
        }
        disconnect()
    }

    private func connectionLost() {
        guard !journal.isFinished else { return }
        if sessionID != nil || spec.resume != nil { journal.requireReconciliation() }
        journal.finish(.interrupted)
    }

    func disconnect() {
        peer?.close()
        process?.terminate()
    }
}

private extension GrokACPRun {
    private func handle(_ method: String, _ params: [String: Any]) {
        if method != "session/update" { return track(method, params) }
        guard params["sessionId"] as? String == sessionID else { return }
        guard let update = params["update"] as? [String: Any] else { return }
        switch update["sessionUpdate"] as? String {
        case "config_option_update":
            configure(update)
        case "agent_message_chunk", "agent_thought_chunk":
            let thought = update["sessionUpdate"] as? String == "agent_thought_chunk"
            renderText(update, params: params, kind: thought ? .reasoning : .agent)
        case "tool_call_update", "tool_call": renderTool(update)
        case "plan":
            let steps = (update["entries"] as? [[String: Any]] ?? []).map {
                PlanStep(status: $0["status"] as? String, text: $0["content"] as? String ?? "")
            }
            if !steps.isEmpty { journal.record(.plan, PlanStep.body(steps)) }
        default:
            break
        }
    }

    private func renderText(_ update: [String: Any], params: [String: Any], kind: TranscriptItem.Kind) {
        guard let text = (update["content"] as? [String: Any])?["text"] as? String else { return }
        let metadata = params["_meta"] as? [String: Any] ?? [:]
        let suffix = kind == .reasoning ? "/thought" : "/text"
        let nativeID = (metadata["promptId"] as? String).flatMap { prompt in
            (metadata["streamStartMs"] as? NSNumber).map { "grok/\(sessionID ?? "")/\(prompt)/\($0)" + suffix }
        }
        if loading, let nativeID {
            journal.reconcileText(text, kind: kind, nativeID: nativeID)
        } else {
            journal.text(text, kind: kind, nativeID: nativeID)
        }
    }

    private func renderTool(_ update: [String: Any]) {
        let toolID = (update["toolCallId"] as? String).map { "grok/\(sessionID ?? "")/tool/" + $0 }
        if update["sessionUpdate"] as? String == "tool_call" {
            journal.record(.tool, update["title"] as? String ?? "tool", nativeID: toolID)
        }
        for (index, block) in (update["content"] as? [[String: Any]] ?? []).enumerated() {
            if let text = (block["content"] as? [String: Any])?["text"] as? String {
                journal.record(.output, text, nativeID: toolID.map { $0 + "/\(index)" })
            }
        }
    }

    private func track(_ method: String, _ params: [String: Any]) {
        if params["sessionId"] as? String == sessionID,
           (params["update"] as? [String: Any])?["sessionUpdate"] as? String == "retry_state" {
            journal.record(.status, "Grok updated its request retry state")
        }
        guard let sessionID, activity.read(method, params, session: sessionID) else { return }
        // A woken turn's text arrives as ordinary updates; its end closes that message.
        if (params["update"] as? [String: Any])?["sessionUpdate"] as? String == "turn_completed" {
            journal.endText()
            let update = params["update"] as? [String: Any]
            let outcome = GrokRecovery.outcome(update?["stop_reason"] as? String)
            if routineOutcome == nil || outcome != .succeeded { routineOutcome = outcome }
        }
        guard !loading else { return }
        finishIfIdle()
    }

}

/// What a Grok session still has going after its prompts return, read from the
/// leader's `_x.ai/` notifications (grok 1.0.70, live 2026-10-26):
/// `queue/changed` names the running turn (`runningPromptId`) and the queued
/// prompts, `background_tasks` lists every task with its status, a finished
/// task or subagent says whether it `will_wake` the session, and
/// `turn_completed` names the turn it ends by `prompt_id`. A woken turn runs
/// under its own prompt id, with its text on the ordinary `session/update`.
struct GrokActivity {
    private var runningPrompt: String?
    private var queued = false
    private var tasks: Set<String> = []
    private var subagents: Set<String> = []
    private var wakePending = false

    /// Background tasks and subagents still running.
    var running: Int { tasks.count + subagents.count }

    var idle: Bool { runningPrompt == nil && !queued && running == 0 && !wakePending }

    mutating func adoptRunning(_ id: String) { runningPrompt = id }

    /// Applies one notification of `session`; true when it was about this session's activity.
    mutating func read(_ method: String, _ params: [String: Any], session: String) -> Bool {
        guard method.hasPrefix("_x.ai/"), params["sessionId"] as? String == session else { return false }
        if method == "_x.ai/queue/changed" {
            runningPrompt = params["runningPromptId"] as? String
            queued = !((params["entries"] as? [Any])?.isEmpty ?? true)
            return true
        }
        guard let update = params["update"] as? [String: Any] else { return false }
        return apply(update)
    }

    mutating func apply(_ update: [String: Any]) -> Bool {
        if update["will_wake"] as? Bool == true { wakePending = true }
        switch update["sessionUpdate"] as? String {
        case "background_tasks":
            let list = update["tasks"] as? [[String: Any]] ?? []
            tasks = Set(list.filter { $0["status"] as? String == "running" }.compactMap { $0["task_id"] as? String })
        case "subagent_spawned":
            if let id = update["subagent_id"] as? String { subagents.insert(id) }
        case "subagent_finished":
            if let id = update["subagent_id"] as? String { subagents.remove(id) }
        case "turn_completed":
            // The woken turn announces its wake after it starts, so its end settles the wake too.
            if let prompt = update["prompt_id"] as? String, prompt == runningPrompt { runningPrompt = nil }
            wakePending = false
        case "task_completed":
            break
        default:
            return false
        }
        return true
    }
}

import Foundation

/// A Grok routine run through the shared leader over ACP (`grok agent --leader
/// stdio`), so messages from Rota join the live session. Protocol:
/// ~/.grok/docs/user-guide/15-agent-mode.md.
final class GrokACPRun: RunControl, @unchecked Sendable {
    private lazy var requests = SessionRequests(changed: journal.requests)
    private let spec: LaunchSpec
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.grok")
    private var process: Process?
    private var peer: JSONRPCPeer?
    private var sessionID: String?
    private var supportsImages = false
    private var stopReason: RunOutcome?
    /// The initial prompt and interject acknowledgments still in flight; do not
    /// disconnect before a user's message has a confirmed outcome.
    private var openPrompts = 0
    private var routineOutcome: RunOutcome?
    /// True while `session/load` replays history, which must not reach the log again.
    private var loading = false
    private let mapper = GrokEventMapper()

    private init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) -> GrokACPRun {
        let run = GrokACPRun(spec: spec, journal: journal)
        run.queue.async { run.connect() }
        return run
    }

    func respond(_ id: String, response: SessionResponse) {
        queue.async { _ = self.requests.answer(id, response) }
    }

    func stop() {
        queue.async { self.cancel(as: .cancelled) }
    }

    func send(_ message: String) { send(message, id: UUID().uuidString) }

    func send(_ message: String, id: String) { send(ChatMessage(text: message), id: id) }

    func send(_ message: ChatMessage, id: String) {
        queue.async {
            self.journal.user(message, id: id)
            guard let sessionID = self.sessionID, !self.journal.isFinished,
                  self.stopReason == nil, let peer = self.peer else {
                return self.journal.delivery(id, .failed("The session cannot accept steering now."))
            }
            self.journal.line(Transcript.userLines(message.fileReferenceText), structured: false)
            self.openPrompts += 1
            let params: [String: Any] = ["sessionId": sessionID, "text": message.fileReferenceText]
            peer.request("_x.ai/interject", params, timeout: 10) { result in
                switch result {
                case .success(let value):
                    self.journal.delivery(id, Self.interjectionDelivery(value))
                case .failure(let error):
                    let state: MessageDelivery = error.deliveryUncertain
                        ? .unconfirmed(error.message) : .failed(error.message)
                    self.journal.delivery(id, state)
                }
                self.openPrompts -= 1
                self.finishIfReady()
            }
        }
    }

    /// Transport flags only; tool permissions come from Grok's configuration.
    static func arguments(_ spec: LaunchSpec) -> [String] {
        ["agent", "--leader"] + spec.modelFlags(effortFlag: "--reasoning-effort") + ["stdio"]
    }

    /// Grok's leader confirms queueing with {"result":{"status":"queued"}}.
    static func interjectionDelivery(_ value: Any) -> MessageDelivery {
        let response = value as? [String: Any]
        if let accepted = response?["accepted"] as? Bool {
            return accepted ? .accepted : .failed("Grok did not accept the interjection.")
        }
        if (response?["result"] as? [String: Any])?["status"] as? String == "queued" { return .queued }
        return .unconfirmed("Grok did not confirm whether the message was queued.")
    }

    // MARK: On `queue`

    private func connect() {
        guard !journal.isFinished, stopReason == nil else { return }
        // On the command line, not session/set_config_option: Grok's guide says a
        // model set that way is synced to the leader's other clients.
        let arguments = Self.arguments(spec)
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
                                                        output: stdout.fileHandleForReading),
                               callbackQueue: queue)
        peer.onNotification = { [weak self] method, params in self?.handle(method, params) }
        peer.onAsyncRequest = { [weak self] method, params, _, reply in
            guard method == "session/request_permission" else { return reply(nil) }
            guard let self, !self.journal.isFinished, self.stopReason == nil,
                  params["sessionId"] as? String == self.sessionID,
                  let request = RequestPresentation.grok(params) else {
                return reply(Self.answer(method, params))
            }
            self.requests.add(request, answer: { response in
                reply(["outcome": ["outcome": "selected", "optionId": response.choice]])
            }, cancel: { reply(Self.answer(method, params)) })
        }
        peer.onClose = { [weak self] in
            self?.requests.cancelAll(notifyProvider: false)
            self?.journal.finish(.interrupted)
        }
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
        guard stopReason == nil, !journal.isFinished else {
            journal.finish(stopReason ?? .cancelled)
            return disconnect()
        }
        guard case .success(let value) = result else { return fail(result, "initialize") }
        let capabilities = (value as? [String: Any])?["agentCapabilities"] as? [String: Any]
        supportsImages = (capabilities?["promptCapabilities"] as? [String: Any])?["image"] as? Bool == true
        var params: [String: Any] = ["cwd": spec.workingDirectory, "mcpServers": [Any]()]
        // Grok's commands run under its shared leader, which has no per-session
        // environment; the session learns who it is from a rule instead.
        if let rule = Self.sessionRule(spec.environment) { params["_meta"] = ["rules": rule] }
        if let session = spec.resume {
            // Loading replays the session as updates; they are already in the log.
            params["sessionId"] = session
            loading = true
            peer?.request("session/load", params) { [weak self] result in
                self?.loading = false
                guard case .success = result else { return self?.fail(result, "session/load") ?? () }
                if case .success(let value) = result { self?.captureMetadata(value) }
                self?.sessionReady(session)
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
        captureMetadata(value)
        let options = (value as? [String: Any])?["configOptions"] as? [[String: Any]] ?? []
        let model = options.first { $0["id"] as? String == "model" }?["currentValue"] as? String
        journal.line("[grok session \(id)" + (model.map { ", \($0)" } ?? "") + "]", structured: false)
        sessionReady(id)
    }

    private func captureMetadata(_ value: Any) {
        let options = (value as? [String: Any])?["configOptions"] as? [[String: Any]] ?? []
        let model = options.first { $0["id"] as? String == "model" }?["currentValue"] as? String
        let effort = options.first { $0["id"] as? String == "reasoning_effort" }?["currentValue"] as? String
        journal.metadata(model: model, effort: effort ?? spec.effort)
    }

    private func sessionReady(_ id: String) {
        sessionID = id
        journal.session(id)
        guard stopReason == nil, !journal.isFinished else {
            peer?.notify("session/cancel", ["sessionId": id])
            journal.finish(stopReason ?? .cancelled)
            return disconnect()
        }
        let content: [[String: Any]]
        do { content = try spec.chatMessage.acpContent(images: supportsImages) } catch {
            journal.finish(.launchFailed(error.localizedDescription))
            return disconnect()
        }
        let params: [String: Any] = ["sessionId": id, "prompt": content]
        openPrompts += 1
        peer?.request("session/prompt", params) { [weak self] result in
            self?.promptEnded(result, isRoutine: true)
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
        finishIfReady()
    }

    private func finishIfReady() {
        guard openPrompts <= 0, let routineOutcome else { return }
        journal.finish(routineOutcome)
        disconnect()
    }

    private func handle(_ method: String, _ params: [String: Any]) {
        guard method == "session/update", !loading, let update = params["update"] as? [String: Any] else { return }
        for payload in mapper.events(update) {
            switch payload {
            case .delta(let id, let text, let phase):
                journal.delivery(spec.messageID, .accepted)
                if phase == .work { journal.event(payload) } else { journal.text(text, id: id, phase: phase) }
            default:
                journal.endText()
                journal.event(payload)
            }
        }
        switch update["sessionUpdate"] as? String {
        case "tool_call": journal.line("-> \(update["title"] as? String ?? "tool")", structured: false)
        case "plan":
            journal.line(PlanStep.lines(EventContent.plan(update["entries"], textKey: "content")), structured: false)
        default: break
        }
    }

    /// Rota never grants permissions the harness configuration did not already allow.
    static func answer(_ method: String, _ params: [String: Any]) -> Any? {
        guard method == "session/request_permission" else { return nil }
        return ["outcome": ["outcome": "cancelled"]]
    }

    private func cancel(as reason: RunOutcome) {
        guard !journal.isFinished else { return }
        requests.cancelAll()
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
        requests.cancelAll()
        peer?.close()
        process?.terminate()
    }
}

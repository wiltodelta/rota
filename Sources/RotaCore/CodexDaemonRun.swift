import Foundation
import os

/// A Codex routine run on the shared local app-server daemon, so the user can
/// steer the turn from Rota while it works (`turn/steer`) and resume the thread
/// in Codex afterwards. Protocol: `codex app-server generate-json-schema`.
final class CodexDaemonRun: RunControl, @unchecked Sendable {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "codex")

    private lazy var requests = SessionRequests(changed: journal.requests)
    private let spec: LaunchSpec
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.codex")
    private var proxy: Process?
    private var peer: JSONRPCPeer?
    private var threadID: String?
    private var turnID: String?
    private var stopReason: RunOutcome?
    private var interruptSent = false
    private var serverRequests: [String: String] = [:]
    private var fileChanges: [String: Any] = [:]

    private init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) -> CodexDaemonRun {
        let run = CodexDaemonRun(spec: spec, journal: journal)
        run.queue.async { run.connect() }
        return run
    }

    func respond(_ id: String, response: SessionResponse) {
        queue.async { _ = self.requests.answer(id, response) }
    }

    func stop() {
        queue.async { self.interrupt(as: .cancelled) }
    }

    func send(_ message: String) { send(message, id: UUID().uuidString) }

    func send(_ message: String, id: String) { send(ChatMessage(text: message), id: id) }

    func send(_ message: ChatMessage, id: String) {
        queue.async {
            self.journal.user(message, id: id)
            guard let threadID = self.threadID, let turnID = self.turnID,
                  !self.journal.isFinished, self.stopReason == nil else {
                return self.journal.delivery(id, .failed("The session cannot accept steering now."))
            }
            self.journal.line(Transcript.userLines(message.fileReferenceText), structured: false)
            guard let peer = self.peer else { return self.journal.delivery(id, .failed("Connection closed.")) }
            Self.requestSteer(peer, message: message, threadID: threadID, turnID: turnID) { state in
                self.journal.delivery(id, state)
            }
        }
    }

    static func requestSteer(_ peer: JSONRPCPeer, message: String, threadID: String, turnID: String,
                             reply: @escaping (MessageDelivery) -> Void) {
        requestSteer(peer, message: ChatMessage(text: message), threadID: threadID, turnID: turnID, reply: reply)
    }

    static func requestSteer(_ peer: JSONRPCPeer, message: ChatMessage, threadID: String, turnID: String,
                             reply: @escaping (MessageDelivery) -> Void) {
        peer.request("turn/steer", ["threadId": threadID, "expectedTurnId": turnID,
                                    "input": message.codexInput()], timeout: 10) { result in
            switch result {
            case .success(let value):
                let acknowledged = (value as? [String: Any])?["turnId"] as? String == turnID
                reply(acknowledged ? .accepted : .failed("The active turn changed."))
            case .failure(let error):
                reply(error.deliveryUncertain ? .unconfirmed(error.message) : .failed(error.message))
            }
        }
    }

    // MARK: On `queue`

    private func connect() {
        guard !journal.isFinished else { return }
        let (status, output) = ProcessLauncher.capture(spec.executable, ["app-server", "daemon", "start"],
                                                       in: ProcessLauncher.helperDirectory)
        guard status == 0 else {
            return journal.finish(.launchFailed("codex app-server daemon start: \(output.prefix(200))"))
        }
        let process = ProcessLauncher.loginShellProcess(spec.executable, ["app-server", "proxy"],
                                                        in: ProcessLauncher.helperDirectory, environment: [:])
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        proxy = process
        let peer = JSONRPCPeer(transport: WebSocketTransport(input: stdin.fileHandleForWriting,
                                                             output: stdout.fileHandleForReading),
                               callbackQueue: queue)
        peer.onNotification = { [weak self] method, params in self?.handle(method, params) }
        peer.onAsyncRequest = { [weak self] method, params, wireID, reply in
            guard let self else { return reply(nil) }
            self.permission(method, params, wireID: wireID, reply: reply)
        }
        peer.onClose = { [weak self] in
            self?.requests.cancelAll(notifyProvider: false)
            self?.journal.finish(self?.stopReason ?? .interrupted)
            if self?.proxy?.isRunning == true { self?.proxy?.terminate() }
        }
        self.peer = peer
        do {
            try process.run()
        } catch {
            journal.finish(.launchFailed(error.localizedDescription))
            return disconnect()
        }
        peer.request("initialize", ["clientInfo": ["name": "rota", "version": "1"]]) { [weak self] result in
            self?.initialized(result)
        }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.interrupt(as: .timedOut) }
        }
    }

    private func permission(_ method: String, _ params: [String: Any], wireID: String,
                            reply: @escaping (Any?) -> Void) {
        guard !journal.isFinished, stopReason == nil,
              params["threadId"] as? String == threadID,
              params["turnId"] as? String == turnID,
              var request = RequestPresentation.codex(method, params) else { return reply(nil) }
        if method == "item/fileChange/requestApproval", let item = params["itemId"] as? String {
            var details = params
            details["changes"] = fileChanges[item]
            request.detail = RequestPresentation.detail(details)
            if fileChanges[item] == nil {
                request.detail += "\nThe provider has not supplied the changes for review."
                request.choices.removeAll { $0.id == "allow" }
            }
        }
        serverRequests[wireID] = request.id
        requests.add(request, answer: { response in
            self.serverRequests[wireID] = nil
            reply(RequestPresentation.codexResponse(method, params, response))
        }, cancel: { reply(RequestPresentation.codexResponse(method, params, .init(choice: "cancel"))) })
    }

    private func initialized(_ result: Result<Any, JSONRPCError>) {
        guard !journal.isFinished, stopReason == nil else { return disconnect() }
        guard case .success = result else { return fail(result, "initialize") }
        peer?.notify("initialized")
        let params = Self.threadParameters(spec)
        let method = spec.resume == nil ? "thread/start" : "thread/resume"
        peer?.request(method, params) { [weak self] result in
            self?.threadStarted(result)
        }
    }

    /// Omitted permission and sandbox fields let the daemon load the user's configuration.
    static func threadParameters(_ spec: LaunchSpec) -> [String: Any] {
        var params: [String: Any] = ["cwd": spec.workingDirectory]
        if let model = spec.model { params["model"] = model }
        let overrides = configOverrides(spec.environment)
        if !overrides.isEmpty { params["config"] = overrides }
        if let thread = spec.resume { params["threadId"] = thread }
        return params
    }

    /// `shell_environment_policy.set.<NAME>` for each of the run's variables: dotted keys,
    /// so they add to the user's own `set` table rather than replace it.
    static func configOverrides(_ environment: [String: String]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: ProcessLauncher.sessionVariables(environment).map {
            ("shell_environment_policy.set.\($0.key)", $0.value as Any)
        })
    }

    private func threadStarted(_ result: Result<Any, JSONRPCError>) {
        guard !journal.isFinished, stopReason == nil else { return disconnect() }
        guard case .success(let value) = result,
              let thread = (value as? [String: Any])?["thread"] as? [String: Any],
              let id = thread["id"] as? String else {
            return fail(result, spec.resume == nil ? "thread/start" : "thread/resume")
        }
        threadID = id
        // The header names the model the daemon picked, so a chosen one can be checked.
        let model = (value as? [String: Any])?["model"] as? String
        if spec.resume == nil {
            journal.line("[codex thread \(id)" + (model.map { ", \($0)" } ?? "") + "]", structured: false)
        }
        journal.session(id)
        journal.metadata(model: model, effort: (value as? [String: Any])?["reasoningEffort"] as? String ?? spec.effort)
        var params: [String: Any] = ["threadId": id, "input": spec.chatMessage.codexInput()]
        if let model = spec.model { params["model"] = model }
        if let effort = spec.effort { params["effort"] = effort }
        peer?.request("turn/start", params) { [weak self] result in
            guard let self, !self.journal.isFinished else { return }
            guard case .success(let value) = result,
                  let turn = (value as? [String: Any])?["turn"] as? [String: Any],
                  let id = turn["id"] as? String, !id.isEmpty else {
                return self.fail(result, "turn/start")
            }
            self.turnID = id
            self.journal.delivery(self.spec.messageID, .accepted)
            self.sendInterruptIfReady()
        }
    }

    private func handle(_ method: String, _ params: [String: Any]) {
        if let thread = params["threadId"] as? String, thread != threadID { return }
        if method == "serverRequest/resolved", let wireID = params["requestId"],
           let id = serverRequests.removeValue(forKey: JSONRPCPeer.requestIdentity(wireID)) {
            requests.cancel(id, notifyProvider: false)
        }
        if method == "turn/started", turnID == nil {
            turnID = (params["turn"] as? [String: Any])?["id"] as? String
            sendInterruptIfReady()
        }
        if let turn = params["turnId"] as? String, let turnID, turn != turnID { return }
        if method == "item/started" || method == "item/completed",
           let item = params["item"] as? [String: Any], item["type"] as? String == "fileChange",
           let id = item["id"] as? String { fileChanges[id] = item["changes"] }
        for payload in CodexEventMapper.events(method, params) { journal.event(payload) }
        logEvent(method, params)
    }

    private func logEvent(_ method: String, _ params: [String: Any]) {
        switch method {
        case "item/started":
            if let line = Self.describe(started: params["item"] as? [String: Any]) {
                journal.line(line, structured: false)
            }
        case "item/completed":
            let item = params["item"] as? [String: Any]
            if item?["type"] as? String == "agentMessage", let text = item?["text"] as? String {
                journal.line(text, structured: false)
            }
        case "turn/plan/updated":
            let steps = (params["plan"] as? [[String: Any]] ?? []).map {
                PlanStep(status: $0["status"] as? String, text: $0["step"] as? String ?? "")
            }
            if !steps.isEmpty { journal.line(PlanStep.lines(steps), structured: false) }
        case "turn/completed":
            turnCompleted(params["turn"] as? [String: Any])
        default:
            break
        }
    }

    private func turnCompleted(_ turn: [String: Any]?) {
        guard let turnID, turn?["id"] as? String == turnID else { return }
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
        guard !journal.isFinished, stopReason == nil else { return }
        requests.cancelAll()
        stopReason = reason
        guard threadID != nil else {
            journal.finish(reason)
            return disconnect()
        }
        // A turn/start already on the wire can be accepted after Stop. Keep the
        // connection until its reply or notification supplies the turn identity.
        sendInterruptIfReady()
        // If the daemon never confirms, end the run anyway.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.journal.isFinished else { return }
            self.journal.line("[warning] Codex did not confirm that the turn stopped. "
                + "Check the thread before retrying.")
            self.journal.finish(reason)
            self.disconnect()
        }
    }

    private func sendInterruptIfReady() {
        guard stopReason != nil, !interruptSent, !journal.isFinished, let threadID, let turnID else { return }
        interruptSent = true
        peer?.request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) { _ in }
    }

    private func fail(_ result: Result<Any, JSONRPCError>, _ step: String) {
        let reason: String
        switch result {
        case .failure(let error): reason = error.message
        case .success: reason = "The provider returned an invalid response."
        }
        journal.finish(stopReason ?? .launchFailed("\(step): \(reason)"))
        disconnect()
    }

    private func disconnect() {
        requests.cancelAll()
        serverRequests.removeAll()
        peer?.close()
        proxy?.terminate()
    }
}

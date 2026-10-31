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
    private var pendingMessages: [String] = []
    private var approvalItems: [String: [String: Any]] = [:]
    private var stopReason: RunOutcome?
    private var turnStarting = false
    private var loadingHistory = false
    private var deferredEvents: [(String, [String: Any])] = []
    private var latestRestoredTurn: [String: Any]?
    private var nativeActive = false
    private var nativeStateKnown: Bool
    private var asyncQuestions: CodexAsyncQuestions

    init(spec: LaunchSpec, journal: RunJournal, peer: JSONRPCPeer? = nil) {
        self.spec = spec
        self.journal = journal
        threadID = spec.resume
        self.peer = peer
        nativeStateKnown = spec.resume == nil
        asyncQuestions = CodexAsyncQuestions()
        // A prompt answering an async question continues the thread whose history still holds it open.
        if spec.resume != nil, !spec.adopt { asyncQuestions.sending(spec.prompt) }
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
            guard !self.journal.isFinished else { return self.journal.undelivered(message) }
            self.asyncQuestions.sending(message)
            self.pendingMessages.append(message)
            self.deliverPendingMessages()
        }
    }

    private func deliverPendingMessages() {
        guard let threadID, let turnID, let peer else { return }
        let messages = pendingMessages
        pendingMessages = []
        for message in messages {
            journal.record(.user, message)
            peer.request("turn/steer", ["threadId": threadID, "expectedTurnId": turnID,
                                       "input": HarnessInput.blocks(message, for: .codexDaemon)]) { result in
                if case .failure(let error) = result {
                    self.journal.line("[rota: message not delivered: \(error.message)]")
                    if let question = self.asyncQuestions.undelivered(message) { self.ask(question) }
                } else if let id = self.asyncQuestions.delivered(message) {
                    self.journal.resolveQuestion(id)
                }
            }
        }
    }

    func turnStarted(_ result: Result<Any, JSONRPCError>) {
        let boxed = UncheckedSendable(result)
        queue.async {
            guard !self.journal.isFinished else { return }
            guard case .success(let value) = boxed.value,
                  let turn = (value as? [String: Any])?["turn"] as? [String: Any],
                  let id = turn["id"] as? String else {
                if let question = self.asyncQuestions.undelivered(self.spec.prompt) { self.ask(question) }
                return self.fail(boxed.value, "turn/start")
            }
            if let id = self.asyncQuestions.delivered(self.spec.prompt) { self.journal.resolveQuestion(id) }
            self.turnID = id
            self.turnStarting = false
            if let reason = self.stopReason { self.interrupt(as: reason) } else { self.deliverPendingMessages() }
        }
    }

    // MARK: On `queue`

    private func connect() {
        let (status, output) = ProcessLauncher.capture(spec.executable, ["app-server", "daemon", "start"],
                                                       in: ProcessLauncher.helperDirectory, timeout: 15)
        guard status == 0 else {
            return finish(.launchFailed("codex app-server daemon start: \(output.prefix(200))"))
        }
        let process = ProcessLauncher.loginShellProcess(spec.executable, ["app-server", "proxy"],
                                                        in: ProcessLauncher.helperDirectory, environment: [:])
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return finish(.launchFailed(error.localizedDescription))
        }
        proxy = process
        let peer = JSONRPCPeer(transport: WebSocketTransport(input: stdin.fileHandleForWriting,
                                                             output: stdout.fileHandleForReading),
                               callbackQueue: queue)
        peer.onNotification = { [weak self] method, params in self?.handle(method, params) }
        peer.onRequestAsync = { [weak self] id, method, params, reply in
            guard let self else { return reply(nil) }
            self.handleRequest(id, method: method, params: params, reply: reply)
        }
        peer.onClose = { [weak self] in self?.finish(.interrupted) }
        self.peer = peer
        peer.request("initialize", ["clientInfo": ["name": "rota", "version": "1"],
                                    "capabilities": ["experimentalApi": true]]) { [weak self] result in
            self?.initialized(result)
        }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.interrupt(as: .timedOut) }
        }
    }

    func initialized(_ result: Result<Any, JSONRPCError>) {
        guard !journal.isFinished else { return }
        guard case .success(let value) = result else { return fail(result, "initialize") }
        journal.provenance(server: (value as? [String: Any])?["userAgent"] as? String)
        peer?.notify("initialized")
        var params: [String: Any] = ["cwd": spec.workingDirectory, "approvalPolicy": "never",
                                     "sandbox": "danger-full-access"]
        if let model = spec.model { params["model"] = model }
        // The daemon's commands inherit the daemon's environment, not this run's, so the
        // run's variables reach them as a per-thread config override.
        let bridge = SessionBridge.codex(spec)
        params["config"] = Self.configOverrides(spec.environment).merging(bridge) { _, scoped in scoped }
        // A continued session loads its thread back onto the daemon and takes the next turn.
        let method = spec.resume == nil ? "thread/start" : "thread/resume"
        loadingHistory = spec.resume != nil
        if loadingHistory { asyncQuestions.hold() }
        if let thread = spec.resume { params["threadId"] = thread }
        requestThread(method, params)
    }

    private func requestThread(_ method: String, _ params: [String: Any], restoringArchive: Bool = true) {
        peer?.request(method, params) { [weak self] result in
            guard let self else { return }
            guard restoringArchive, !self.spec.adopt, let id = self.spec.resume,
                  case .failure(let error) = result,
                  error.message.hasPrefix("session \(id) is archived.") else { return self.threadStarted(result) }
            // Explicit continuation restores the archive through Codex, never by moving its files.
            self.peer?.request("thread/unarchive", ["threadId": id]) { [weak self] restored in
                guard let self else { return }
                guard case .success = restored else { return self.fail(restored, "thread/unarchive") }
                self.journal.record(.status, "Restored archived Codex session")
                self.requestThread(method, params, restoringArchive: false)
            }
        }
    }

    /// `shell_environment_policy.set.<NAME>` for each of the run's variables: dotted keys,
    /// so they add to the user's own `set` table rather than replace it.
    static func configOverrides(_ environment: [String: String]) -> [String: Any] {
        var config: [String: Any] = Dictionary(uniqueKeysWithValues: ProcessLauncher.sessionVariables(environment).map {
            ("shell_environment_policy.set.\($0.key)", $0.value as Any)
        })
        config["features.default_mode_request_user_input"] = true
        return config
    }

    func threadStarted(_ result: Result<Any, JSONRPCError>) {
        guard !journal.isFinished else { return }
        guard case .success(let value) = result,
              let thread = (value as? [String: Any])?["thread"] as? [String: Any],
              let id = thread["id"] as? String else {
            return fail(result, spec.resume == nil ? "thread/start" : "thread/resume")
        }
        threadID = id
        // The header names the model the daemon picked, so a chosen one can be checked.
        let model = (value as? [String: Any])?["model"] as? String
        journal.configure(SessionConfiguration(model: model,
            effort: spec.effort ?? (value as? [String: Any])?["reasoningEffort"] as? String))
        if spec.resume == nil { journal.line("[codex thread \(id)" + (model.map { ", \($0)" } ?? "") + "]") }
        journal.session(id)
        nativeActive = (thread["status"] as? [String: Any])?["type"] as? String == "active"
        if spec.resume != nil { return restoreTurns(id) }
        beginTurn(id)
    }

    private func beginTurn(_ id: String) {
        guard !journal.isFinished, stopReason == nil else { return }
        var params: [String: Any] = ["threadId": id, "input": HarnessInput.blocks(spec.prompt, for: .codexDaemon)]
        if let model = spec.model { params["model"] = model }
        if let effort = spec.effort { params["effort"] = effort }
        turnStarting = true
        peer?.request("turn/start", params) { [weak self] result in
            self?.turnStarted(result)
        }
    }

    private func restoreTurns(_ id: String, cursor: String? = nil) {
        var params: [String: Any] = ["threadId": id, "limit": 100, "sortDirection": "asc", "itemsView": "full"]
        if let cursor { params["cursor"] = cursor }
        peer?.request("thread/turns/list", params) { [weak self] result in
            guard let self, !self.journal.isFinished else { return }
            guard case .success(let value) = result, let page = value as? [String: Any],
                  let turns = page["data"] as? [[String: Any]] else { return self.fail(result, "thread/turns/list") }
            for turn in turns {
                self.latestRestoredTurn = turn
                for item in turn["items"] as? [[String: Any]] ?? [] {
                    self.itemStarted(item)
                    self.itemCompleted(item)
                }
            }
            if let next = page["nextCursor"] as? String { return self.restoreTurns(id, cursor: next) }
            self.historyRestored(id)
        }
    }

    private func historyRestored(_ id: String) {
        loadingHistory = false
        nativeStateKnown = true
        let active = latestRestoredTurn?["status"] as? String == "inProgress"
        if active { turnID = latestRestoredTurn?["id"] as? String }
        let deferred = deferredEvents
        deferredEvents = []
        // A deferred completion must not finish the journal before open questions are published.
        for (method, params) in deferred where method != "turn/completed" { handle(method, params) }
        guard !journal.isFinished else { return }
        asyncQuestions.closed.forEach(journal.resolveQuestion)
        asyncQuestions.restored().forEach(ask)
        for (method, params) in deferred where method == "turn/completed" { handle(method, params) }
        guard !journal.isFinished else { return }
        if active, let turnID { return continueActiveTurn(id, turnID: turnID) }
        guard !nativeActive else {
            journal.line("[error] Codex reports active work without a recoverable turn. No second turn was started.")
            finish(.interrupted)
            return disconnect()
        }
        if spec.adopt {
            turnID = latestRestoredTurn?["id"] as? String
            turnCompleted(latestRestoredTurn)
        } else {
            beginTurn(id)
        }
    }

    private func continueActiveTurn(_ id: String, turnID: String) {
        if let reason = stopReason { return interrupt(as: reason) }
        if !spec.adopt {
            peer?.request("turn/steer", ["threadId": id, "expectedTurnId": turnID,
                "input": HarnessInput.blocks(spec.prompt, for: .codexDaemon)]) { [weak self] result in
                guard let self else { return }
                if case .failure = result {
                    if let question = self.asyncQuestions.undelivered(self.spec.prompt) { self.ask(question) }
                    self.fail(result, "turn/steer")
                } else if let id = self.asyncQuestions.delivered(self.spec.prompt) {
                    self.journal.resolveQuestion(id)
                }
            }
        }
        deliverPendingMessages()
    }

    private func interrupt(as reason: RunOutcome) {
        guard !journal.isFinished else { return }
        stopReason = reason
        guard let threadID, let turnID else {
            if turnStarting || !nativeStateKnown {
                // Keep the connection until start identifies the turn we must cancel.
                queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.cancellationUnconfirmed() }
                return
            }
            finish(reason, nativeFinal: true)
            return disconnect()
        }
        peer?.request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) { _ in }
        // A missing confirmation keeps the routine reserved.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.cancellationUnconfirmed()
        }
    }

    private func cancellationUnconfirmed() {
        guard !journal.isFinished else { return }
        journal.record(.status, "Codex has not confirmed cancellation; waiting for the native turn")
        if let reason = stopReason { interrupt(as: reason) }
    }

    private func fail(_ result: Result<Any, JSONRPCError>, _ step: String) {
        let reason: String
        if case .failure(let error) = result { reason = error.message } else { reason = "Malformed reply" }
        let absent = step == "thread/resume" && reason.hasPrefix("no rollout found for thread id ")
        finish(.launchFailed("\(step): \(reason)"), nativeFinal: absent)
        disconnect()
    }

    private func finish(_ outcome: RunOutcome, nativeFinal: Bool = false) {
        guard !journal.isFinished else { return }
        if threadID != nil, !nativeFinal { journal.requireReconciliation() }
        for message in pendingMessages {
            journal.record(.user, message)
            journal.line("[rota: message not delivered: the turn did not become ready]")
            if let question = asyncQuestions.undelivered(message) { ask(question) }
        }
        pendingMessages = []
        journal.finish(outcome)
    }

    func disconnect() {
        peer?.close()
        proxy?.terminate()
    }
}

extension CodexDaemonRun {
    /// The daemon broadcasts other roots and child threads on the same connection.
    /// Their root's collaboration items already describe child work; child messages
    /// must never become this session's answers, questions, plans or completion.
    private func owns(_ params: [String: Any]) -> Bool {
        guard let threadID, let source = params["threadId"] as? String else { return false }
        return source == threadID
    }

    func handleRequest(_ id: String, method: String, params: [String: Any], reply: @escaping (Any?) -> Void) {
        guard owns(params), !journal.isFinished else {
            // A reply would resolve a request belonging to another client.
            peer?.dismissRequest(id)
            return
        }
        var details = params
        if let itemID = params["itemId"] as? String, let item = approvalItems[itemID] {
            details["fileChanges"] = item["changes"]
        }
        guard var request = QuestionRequest.codex(method, details) else { return reply(nil) }
        request.question.id = id
        let boxed = UncheckedSendable((request, reply))
        journal.ask(request.question) { answer in
            self.queue.async { boxed.value.1(boxed.value.0.response(answer)) }
        }
    }

    func handle(_ method: String, _ params: [String: Any]) {
        guard owns(params), !journal.isFinished else { return }
        if loadingHistory { deferredEvents.append((method, params)); return }
        if method.hasPrefix("item/") { return handleItem(method, params) }
        switch method {
        case "serverRequest/resolved": resolveRequest(params)
        case "error":
            let message = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex request error"
            journal.record(params["willRetry"] as? Bool == true ? .status : .error, message)
        case "turn/started": nativeTurnStarted(params)
        case "turn/plan/updated": updatePlan(params)
        case "turn/completed":
            turnCompleted(params["turn"] as? [String: Any])
        default:
            break
        }
    }

    private func nativeTurnStarted(_ params: [String: Any]) {
        guard let id = (params["turn"] as? [String: Any])?["id"] as? String else { return }
        turnID = id
        if let reason = stopReason { interrupt(as: reason) }
    }

    private func updatePlan(_ params: [String: Any]) {
        let steps = (params["plan"] as? [[String: Any]] ?? []).map {
            PlanStep(status: $0["status"] as? String, text: $0["step"] as? String ?? "")
        }
        if !steps.isEmpty { journal.record(.plan, PlanStep.body(steps)) }
    }

    private func resolveRequest(_ params: [String: Any]) {
        guard let id = params["requestId"] else { return }
        let key = String(describing: id)
        peer?.dismissRequest(key)
        journal.resolveQuestion(key)
    }

    private func handleItem(_ method: String, _ params: [String: Any]) {
        switch method {
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let delta = params["delta"] as? String, let id = params["itemId"] as? String {
                let agent = method == "item/agentMessage/delta"
                let summary = method == "item/reasoning/summaryTextDelta"
                let index = params[summary ? "summaryIndex" : "contentIndex"] as? Int ?? 0
                let suffix = agent ? "" : (summary ? "/summary/" : "/content/") + String(index)
                journal.text(delta, kind: agent ? .agent : .reasoning, nativeID: "codex/" + id + suffix)
            }
        case "item/started": itemStarted(params["item"] as? [String: Any])
        case "item/completed": itemCompleted(params["item"] as? [String: Any])
        default: break
        }
    }

    private func itemCompleted(_ item: [String: Any]?) {
        guard let item else { return }
        if let id = item["id"] as? String { approvalItems[id] = nil }
        let nativeID = "codex/" + (item["id"] as? String ?? UUID().uuidString)
        if item["type"] as? String == "agentMessage", let text = item["text"] as? String {
            journal.reconcileText(text, kind: .agent, nativeID: nativeID)
        }
        completedReasoning(item, nativeID: nativeID)
        completedOutput(item, nativeID: nativeID)
        asyncQuestions.noteAnswers(in: item).forEach(journal.resolveQuestion)
        if let question = QuestionRequest.codexMessage(item), let open = asyncQuestions.offer(question) { ask(open) }
    }

    private func ask(_ question: AgentQuestion) {
        journal.ask(question, recordText: false) { _ in }
    }

    private func completedReasoning(_ item: [String: Any], nativeID: String) {
        guard item["type"] as? String == "reasoning" else { return }
        for field in ["summary", "content"] {
            for (index, text) in (item[field] as? [String] ?? []).enumerated() {
                journal.reconcileText(text, kind: .reasoning, nativeID: nativeID + "/\(field)/\(index)")
            }
        }
    }

    private func completedOutput(_ item: [String: Any], nativeID: String) {
        for entry in CodexItemOutput.entries(item) {
            journal.record(entry.kind, entry.text, nativeID: nativeID + entry.suffix)
        }
    }

    private func itemStarted(_ item: [String: Any]?) {
        if let item, item["type"] as? String == "subAgentActivity",
           let text = CodexItemOutput.activity(item), let id = item["id"] as? String {
            journal.record(.status, text, nativeID: "codex/" + id + "/activity")
        }
        if let item, item["type"] as? String == "fileChange", let id = item["id"] as? String {
            approvalItems[id] = item
        }
        if let title = Self.describe(started: item) {
            journal.record(.tool, title, nativeID: (item?["id"] as? String).map { "codex/" + $0 + "/tool" })
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
        finish(outcome, nativeFinal: true)
        disconnect()
    }

    static func describe(started item: [String: Any]?) -> String? {
        switch item?["type"] as? String {
        case "commandExecution": return (item?["command"] as? String).map { "$ \($0)" }
        case "mcpToolCall": return item?["tool"] as? String
        case "dynamicToolCall": return item?["tool"] as? String
        case "collabAgentToolCall": return "agent " + (item?["tool"] as? String ?? "collaboration")
        case "fileChange": return "edit files"
        case "imageView": return "view image"
        case "imageGeneration": return "generate image"
        case "webSearch": return (item?["query"] as? String).map { "search \($0)" }
        default: return nil
        }
    }

}

import Darwin
import Foundation
import os

/// A Claude routine run the way Claude Desktop runs its sessions: `claude -p`
/// with stream-json in both directions. The prompt and every later message go
/// in as user messages on stdin, so a message sent while Claude works joins the
/// current turn; the `result` event ends the turn, and the run when no
/// background task is left running: a finishing task starts Claude's next turn,
/// which closing stdin would prevent. A task that finishes while Claude writes
/// its last answer is answered in a turn of its own after the `result` too, so
/// after a notification the run waits `settle` for that turn's `init`. A
/// finished session continues with `--resume <session id>`.
final class ClaudeStreamRun: RunControl, @unchecked Sendable {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "claude")

    private let spec: LaunchSpec
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.claude")
    private var hookSettings: URL?
    private var capture: DurableStream?
    private var recoveredOutcome: RunOutcome?
    private var input: FileHandle?
    private var stopReason: RunOutcome?
    private var questions: [String: String] = [:]
    /// Background shells and agents running, as `background_tasks_changed` last listed them.
    private var background: Set<String> = []
    /// A background task finished during this turn; Claude may answer it in a turn of its own.
    private var notified = false
    private var turns = 0
    private var streamedText = false
    private var streamedReasoning = false
    var settle: TimeInterval = 5

    init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> ClaudeStreamRun {
        let run = ClaudeStreamRun(spec: spec, journal: journal)
        do {
            if spec.adopt { try run.restore() } else { try run.launch() }
        } catch {
            if let settings = run.hookSettings { try? FileManager.default.removeItem(at: settings) }
            run.capture?.stop(on: run.queue)
            throw error
        }
        return run
    }

    /// The `claude` arguments for a run: `resume` continues that session, and
    /// `chrome` passes on the user's Chrome default, which print mode would not apply.
    static func arguments(chrome: Bool, resume: String?) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--permission-mode", "bypassPermissions", "--permission-prompt-tool", "stdio",
                         "--include-partial-messages"]
        if chrome { arguments.append("--chrome") }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// One user message on the stream-json input.
    static func userMessage(_ text: String) -> Data {
        let message: [String: Any] = ["type": "user",
                                      "message": ["role": "user",
                                                  "content": HarnessInput.blocks(text, for: .claudeStream)]]
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return data + Data("\n".utf8)
    }

    private func launch() throws {
        let settings = try ClaudeRunSettings.hooks(in: spec.log.deletingLastPathComponent())
        hookSettings = settings
        let capture = try DurableStream(spec: spec, arguments: spec.arguments + ["--settings", settings.path]
            + spec.modelFlags(effortFlag: "--effort"))
        self.capture = capture
        input = capture.input
        queue.async { self.followCapture() }
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1)
        try input?.write(contentsOf: ClaudeConfiguration.request("initialize", id: ClaudeConfiguration.initializeID))
        try input?.write(contentsOf: ClaudeConfiguration.request("get_settings", id: ClaudeConfiguration.settingsID))
        try input?.write(contentsOf: Self.userMessage(spec.prompt))
        if let session = spec.resume { journal.session(session) }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(as: .timedOut) }
        }
    }

    private func restore() throws {
        capture = try DurableStream(restoring: spec.log)
        if let session = spec.resume { journal.session(session) }
        queue.async { self.followCapture() }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(as: .timedOut) }
        }
    }

    private func followCapture() {
        capture?.follow(on: queue, line: { data, source in
            self.journal.withSource(source) { self.handle(lossyUTF8(data)) }
        }, ended: { self.exited(status: $0) })
    }

    func send(_ message: String) {
        queue.async {
            guard !self.journal.isFinished, let input = self.input else { return self.journal.undelivered(message) }
            self.journal.record(.user, message)
            do {
                try input.write(contentsOf: Self.userMessage(message))
            } catch {
                self.journal.line("[rota: message not delivered: \(error.localizedDescription)]")
            }
        }
    }

    func stop() {
        queue.async { self.end(as: .cancelled) }
    }

    // MARK: On `queue`

    func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else {
            // Not stream-json: an error Claude printed before it started, kept for the reader.
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { journal.line("[error] \(line)") }
            return
        }
        if let configuration = ClaudeConfiguration.applied(event) { journal.configure(configuration) }
        if spec.adopt, type.hasPrefix("control_") { return }
        if handleControl(event) { return }
        switch type {
        case "stream_event": partial(event)
        case "system":
            system(event, line: line)
        case "result":
            turnEnded(event)
        default: message(data, type: type)
        }
    }

    private func partial(_ event: [String: Any]) {
        let event = event["event"] as? [String: Any] ?? [:]
        if ["content_block_stop", "message_stop"].contains(event["type"] as? String ?? "") {
            journal.endText()
        }
        let delta = event["delta"] as? [String: Any] ?? [:]
        if let text = delta["text"] as? String, !text.isEmpty {
            streamedText = true
            journal.text(text)
        } else if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
            streamedReasoning = true
            journal.text(thinking, kind: .reasoning)
        }
    }

    private func message(_ data: Data, type: String) {
        if type == "user" { notified = false }
        for item in StreamJSONFormatter.items(data) {
            let alreadyStreamed = type == "assistant"
                && (item.kind == .agent && streamedText || item.kind == .reasoning && streamedReasoning)
            if !alreadyStreamed { journal.record(item.kind, item.text) }
        }
        if type == "assistant" {
            journal.endText()
            streamedText = false
            streamedReasoning = false
        }
    }

    private func system(_ event: [String: Any], line: String) {
        let subtype = event["subtype"] as? String
        if subtype == "api_retry" {
            journal.record(.status, "Claude is retrying its request")
        } else if subtype == "background_tasks_changed" {
            // `ambient` tasks (watchers such as Monitor) are not activity, by the CLI's own schema.
            let tasks = (event["tasks"] as? [[String: Any]] ?? []).filter { $0["ambient"] as? Bool != true }
            background = Set(tasks.compactMap { $0["task_id"] as? String })
        } else if subtype == "task_notification", let id = event["task_id"] as? String, background.contains(id) {
            notified = true
        } else if subtype == "init", let session = event["session_id"] as? String {
            turns += 1
            notified = false
            // The header names the model Claude picked, so a chosen one can be checked.
            if let header = StreamJSONFormatter.format(line) { journal.line(header) }
            journal.configure(SessionConfiguration(model: event["model"] as? String))
            journal.session(session)
            try? input?.write(contentsOf: ClaudeConfiguration.request("get_settings",
                                                                      id: ClaudeConfiguration.settingsID))
        }
    }

    private func handleControl(_ event: [String: Any]) -> Bool {
        switch event["type"] as? String {
        case "control_request": controlRequest(event)
        case "control_cancel_request":
            if let id = event["request_id"] as? String, let question = questions.removeValue(forKey: id) {
                journal.resolveQuestion(question)
            }
        default: return false
        }
        return true
    }

    private func controlRequest(_ event: [String: Any]) {
        guard let id = event["request_id"] as? String,
              let request = event["request"] as? [String: Any] else { return }
        let subtype = request["subtype"] as? String
        let tool = request["tool_name"] as? String ?? "Tool"
        let input = request["input"] as? [String: Any] ?? [:]
        let translated = QuestionRequest.claude(["hook_event_name": "PreToolUse", "tool_name": tool,
                                                 "tool_input": input])
        let question = translated?.question ?? AgentQuestion(title: "Claude requests approval for " + tool,
            detail: QuestionRequest.json(input), actions: [.init(id: "accept", label: "Allow Once")])
        questions[id] = question.id
        let boxed = UncheckedSendable((translated, input))
        journal.ask(question) { answer in
            self.queue.async {
                guard !self.journal.isFinished, self.questions.removeValue(forKey: id) != nil else { return }
                var response: [String: Any] = ["behavior": "deny", "message": "The user declined this request."]
                if subtype == "can_use_tool", answer.action == "accept" {
                    let output = boxed.value.0?.response(answer)["hookSpecificOutput"] as? [String: Any]
                    response = ["behavior": "allow", "updatedInput": output?["updatedInput"] ?? boxed.value.1]
                }
                let event: [String: Any] = ["type": "control_response", "response": [
                    "subtype": "success", "request_id": id, "response": response]]
                if let data = try? JSONSerialization.data(withJSONObject: event) {
                    try? self.input?.write(contentsOf: data + Data("\n".utf8))
                }
            }
        }
    }

    /// The turn is over. The run ends with it unless a background task still runs
    /// or a notification may start one more turn; closing stdin lets Claude exit and save the session.
    private func turnEnded(_ event: [String: Any]) {
        let failed = event["is_error"] as? Bool == true || (event["subtype"] as? String)?.hasPrefix("error") == true
        if spec.adopt {
            recoveredOutcome = failed ? .failed(exitCode: 1) : .succeeded
            return
        }
        if !failed, stopReason == nil {
            if !background.isEmpty { return journal.record(.status, TranscriptService.waiting(background.count)) }
            if notified { return closeUnlessATurnStarts() }
        }
        if failed, let reason = event["result"] as? String ?? event["subtype"] as? String {
            journal.line("[error] \(reason)")
        }
        close(failed: failed)
    }

    private func closeUnlessATurnStarts() {
        let turn = turns
        queue.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, self.turns == turn else { return }
            self.close(failed: false)
        }
    }

    private func close(failed: Bool) {
        recoveredOutcome = failed ? .failed(exitCode: 1) : .succeeded
        try? input?.close()
        input = nil
    }

    func exited(status: Int32) {
        if capture?.alive == true { journal.requireReconciliation() }
        if let hookSettings { try? FileManager.default.removeItem(at: hookSettings) }
        // Normally the result came first; an exit without one is a crash or a refusal to start.
        journal.finish(stopReason ?? recoveredOutcome
            ?? (status == 0 || status == -1 ? .interrupted : .failed(exitCode: status)))
        Self.log.info("claude exited with \(status)")
    }

    private func end(as reason: RunOutcome) {
        guard !journal.isFinished, capture?.alive == true else { return }
        stopReason = reason
        capture?.stop(on: queue, delay: 10)
    }
}

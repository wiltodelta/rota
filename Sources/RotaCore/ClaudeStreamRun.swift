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
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopReason: RunOutcome?
    private var questions: [String: String] = [:]
    /// Background shells and agents running, as `background_tasks_changed` last listed them.
    private var background: Set<String> = []
    /// A background task finished during this turn; Claude may answer it in a turn of its own.
    private var notified = false
    private var turns = 0
    var settle: TimeInterval = 5

    init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> ClaudeStreamRun {
        let run = ClaudeStreamRun(spec: spec, journal: journal)
        try run.launch()
        return run
    }

    /// The `claude` arguments for a run: `resume` continues that session, and
    /// `chrome` passes on the user's Chrome default, which print mode would not apply.
    static func arguments(chrome: Bool, resume: String?) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--permission-mode", "bypassPermissions", "--permission-prompt-tool", "stdio"]
        if chrome { arguments.append("--chrome") }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// One user message on the stream-json input.
    static func userMessage(_ text: String) -> Data {
        let message: [String: Any] = ["type": "user",
                                      "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return data + Data("\n".utf8)
    }

    private func launch() throws {
        let settings = try ClaudeRunSettings.hooks(in: spec.log.deletingLastPathComponent())
        hookSettings = settings
        let process = ProcessLauncher.loginShellProcess(spec.executable,
                                                        spec.arguments + ["--settings", settings.path]
                                                            + spec.modelFlags(effortFlag: "--effort"),
                                                        in: spec.workingDirectory, environment: spec.environment)
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.queue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let status = finished.terminationStatus
            self.queue.async { self.exited(status: status) }
        }
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: settings)
            throw error
        }
        self.process = process
        input = stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try input?.write(contentsOf: ClaudeConfiguration.request("initialize", id: ClaudeConfiguration.initializeID))
        try input?.write(contentsOf: ClaudeConfiguration.request("get_settings", id: ClaudeConfiguration.settingsID))
        try input?.write(contentsOf: Self.userMessage(spec.prompt))
        if let session = spec.resume { journal.session(session) }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(as: .timedOut) }
        }
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

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = lossyUTF8(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else {
            // Not stream-json: an error Claude printed before it started, kept for the reader.
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { journal.line("[error] \(line)") }
            return
        }
        if let configuration = ClaudeConfiguration.applied(event) { journal.configure(configuration) }
        if handleControl(event) { return }
        switch type {
        case "system":
            system(event, line: line)
        case "result":
            turnEnded(event)
        default:
            // A tool result after a notification means another request, which carries the notification.
            if type == "user" { notified = false }
            for item in StreamJSONFormatter.items(data) { journal.record(item.kind, item.text) }
        }
    }

    private func system(_ event: [String: Any], line: String) {
        let subtype = event["subtype"] as? String
        if subtype == "background_tasks_changed" {
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
        journal.finish(stopReason ?? (failed ? .failed(exitCode: 1) : .succeeded))
        try? input?.close()
        input = nil
    }

    func exited(status: Int32) {
        if let hookSettings { try? FileManager.default.removeItem(at: hookSettings) }
        // Normally the result came first; an exit without one is a crash or a refusal to start.
        journal.finish(stopReason ?? (status == 0 ? .interrupted : .failed(exitCode: status)))
        Self.log.info("claude exited with \(status)")
    }

    private func end(as reason: RunOutcome) {
        guard !journal.isFinished, let process, process.isRunning else { return }
        stopReason = reason
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

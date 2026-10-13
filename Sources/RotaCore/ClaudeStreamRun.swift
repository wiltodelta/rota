import Foundation
import os

/// A Claude routine run the way Claude Desktop runs its sessions: `claude -p`
/// with stream-json in both directions. The prompt and every later message go
/// in as user messages on stdin, so a message sent while Claude works joins the
/// current turn; the `result` event ends the turn and the run. A finished
/// session continues with `--resume <session id>`.
final class ClaudeStreamRun: RunControl, @unchecked Sendable {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "claude")

    private lazy var requests = SessionRequests(changed: journal.requests)
    private let spec: LaunchSpec
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.claude")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let mapper = ClaudeEventMapper()
    private var stopReason: RunOutcome?

    private init(spec: LaunchSpec, journal: RunJournal) {
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
                         "--include-partial-messages",
                         "--replay-user-messages", "--permission-prompt-tool", "stdio"]
        if chrome { arguments.append("--chrome") }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// One user message on the stream-json input.
    static func userMessage(_ text: String) -> Data {
        // Text-only callers cannot fail while loading an attachment.
        (try? userMessage(ChatMessage(text: text))) ?? Data()
    }

    static func userMessage(_ value: ChatMessage) throws -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": try value.claudeContent()]]
        return try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
    }

    private func launch() throws {
        let message = try Self.userMessage(spec.chatMessage)
        let process = ProcessLauncher.loginShellProcess(spec.executable,
                                                        spec.arguments + spec.modelFlags(effortFlag: "--effort"),
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
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        try input?.write(contentsOf: message)
        journal.delivery(spec.messageID, .written)
        if let session = spec.resume { journal.session(session) }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(as: .timedOut) }
        }
    }

    func send(_ message: String) { send(message, id: UUID().uuidString) }

    func send(_ message: String, id: String) { send(ChatMessage(text: message), id: id) }

    func send(_ message: ChatMessage, id: String) {
        queue.async {
            self.journal.user(message, id: id, echo: message.claudeText)
            guard !self.journal.isFinished, let input = self.input else {
                return self.journal.delivery(id, .failed("The session is ending."))
            }
            self.journal.line(Transcript.userLines(message.fileReferenceText), structured: false)
            do {
                try input.write(contentsOf: Self.userMessage(message))
                self.journal.delivery(id, .written)
            } catch {
                self.journal.delivery(id, .failed(error.localizedDescription))
                self.journal.line("[rota: message not delivered: \(error.localizedDescription)]")
            }
        }
    }

    func respond(_ id: String, response: SessionResponse) {
        queue.async { _ = self.requests.answer(id, response) }
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

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else {
            // Not stream-json: an error Claude printed before it started, kept for the reader.
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { journal.line("[error] \(line)") }
            return
        }
        if handleControl(type, event) { return }
        for payload in mapper.events(event) { journal.event(payload) }
        confirmUser(type, event)
        switch type {
        case "system":
            if event["subtype"] as? String == "init", let session = event["session_id"] as? String {
                // The header names the model Claude picked, so a chosen one can be checked.
                if let header = StreamJSONFormatter.format(line) { journal.line(header, structured: false) }
                journal.metadata(model: event["model"] as? String)
                journal.session(session)
            }
        case "result":
            turnEnded(event)
        default:
            if let text = StreamJSONFormatter.format(line) { journal.line(text, structured: false) }
        }
    }

    private func confirmUser(_ type: String, _ event: [String: Any]) {
        if type == "user", let text = ClaudeTranscript.userText(event) { journal.confirmUser(text) }
    }

    private func handleControl(_ type: String, _ event: [String: Any]) -> Bool {
        if type == "control_request", let id = event["request_id"] as? String,
           let request = event["request"] as? [String: Any] {
            permission(id, request)
            return true
        }
        if type == "control_cancel_request", let id = event["request_id"] as? String {
            requests.cancel(id, notifyProvider: false)
            return true
        }
        return false
    }

    private func permission(_ id: String, _ params: [String: Any]) {
        guard !journal.isFinished, stopReason == nil else {
            return controlReply(id, result: ["behavior": "deny", "message": "The session has ended.",
                                             "interrupt": true])
        }
        guard params["subtype"] as? String == "can_use_tool" else {
            return controlReply(id, error: "Unsupported control request")
        }
        var request = RequestPresentation.claude(params)
            ?? RequestPresentation.permission(title: params["title"] as? String
            ?? "Allow " + (params["tool_name"] as? String ?? "Tool") + "?", detail: RequestPresentation.detail(params))
        request.id = id
        requests.add(request, answer: { response in
            let result = RequestPresentation.claudeResponse(params, response)
            self.controlReply(id, result: result)
        }, cancel: {
            self.controlReply(id, result: ["behavior": "deny", "message": "The session was stopped.",
                                          "interrupt": true])
        })
    }

    private func controlReply(_ id: String, result: [String: Any] = [:], error: String? = nil) {
        var response: [String: Any] = ["request_id": id, "subtype": error == nil ? "success" : "error"]
        if let error { response["error"] = error } else { response["response"] = result }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["type": "control_response", "response": response])
            try input?.write(contentsOf: data + Data("\n".utf8))
        } catch { journal.line("[error] Could not send the permission response: " + error.localizedDescription) }
    }

    /// The turn is over: the run ends, and closing stdin lets Claude exit and save the session.
    private func turnEnded(_ event: [String: Any]) {
        let failed = event["is_error"] as? Bool == true || (event["subtype"] as? String)?.hasPrefix("error") == true
        if failed, let reason = event["result"] as? String ?? event["subtype"] as? String {
            journal.line("[error] \(reason)")
        }
        requests.cancelAll()
        journal.finish(stopReason ?? (failed ? .failed(exitCode: 1) : .succeeded))
        try? input?.close()
        input = nil
    }

    private func exited(status: Int32) {
        // Normally the result came first; an exit without one is a crash or a refusal to start.
        requests.cancelAll(notifyProvider: false)
        journal.finish(stopReason ?? (status == 0 ? .succeeded : .failed(exitCode: status)))
        Self.log.info("claude exited with \(status)")
    }

    private func end(as reason: RunOutcome) {
        guard !journal.isFinished, let process, process.isRunning else { return }
        requests.cancelAll()
        stopReason = reason
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

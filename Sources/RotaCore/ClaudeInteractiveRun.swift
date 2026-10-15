import Foundation
import os

/// Interactive Claude on a directly owned controlling PTY. Structured chat still
/// comes from Claude's transcript; terminal bytes remain available through a
/// private attachment socket for native permission and question dialogs.
final class ClaudeInteractiveRun: RunControl, @unchecked Sendable {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "claude")

    private let spec: LaunchSpec
    private let journal: RunJournal
    private let session: String
    private var process: PTYProcess?
    private var terminal: PTYTerminal?
    private var hookServer: ClaudeHookServer?
    private var settingsFile: URL?
    private lazy var requests = SessionRequests(changed: journal.requests)
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.claude-interactive")
    private var transcript: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    /// The prompt is in the log already; its transcript entry is skipped once.
    private var promptPending = true
    private var startup = ClaudePromptEntry()
    private var initialPromptWritten = false
    /// Input arriving during CLI startup waits for its first transcript entry.
    private var startupMessages: [(ChatMessage, String)] = []
    /// Messages typed in and not yet seen in the transcript.
    private var unanswered = 0
    private var turnEnded = false
    private var failed = false
    private var exiting = false
    private var stopReason: RunOutcome?
    private var headerWritten = false
    private let mapper = ClaudeEventMapper()

    private init(spec: LaunchSpec, journal: RunJournal, session: String) {
        self.spec = spec
        self.journal = journal
        self.session = session
    }

    var attachCommand: [String]? {
        guard let terminal, let cli = spec.environment["ROTA_CLI"] else { return nil }
        return [cli, "attach-terminal", terminal.path]
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> ClaudeInteractiveRun {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/terminal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = spec.resume ?? UUID().uuidString.lowercased()
        let run = ClaudeInteractiveRun(spec: spec, journal: journal, session: session)
        let hookServer = try ClaudeHookServer(folder: folder, queue: run.queue)
        run.hookServer = hookServer
        hookServer.received = { [weak run] id, payload, reply in run?.hook(id, payload: payload, reply: reply) }
        hookServer.disconnected = { [weak run] id in run?.requests.cancel(id, notifyProvider: false) }
        do { try run.launch(settings: try hookSettings(in: folder, session: session), folder: folder) } catch {
            run.queue.sync {
                hookServer.close()
                if let file = run.settingsFile { try? FileManager.default.removeItem(at: file) }
            }
            throw error
        }
        return run
    }

    /// Only configuration goes on argv. The initial message uses the owned terminal input.
    static func arguments(session: String, resume: Bool, settings: String, model: [String]) -> [String] {
        [resume ? "--resume" : "--session-id", session, "--settings", settings] + model
    }

    /// Per-run hooks collect question answers and one-time permissions through Rota.
    /// Native prompts outside those hooks still mark the session needs-reply.
    static func hookSettings(in folder: URL, session: String = UUID().uuidString) throws -> URL {
        let command = #"[ -n "$ROTA_SESSION" ] && [ -n "$ROTA_CLI" ] && "$ROTA_CLI" notify --needs-reply "#
            + #""Claude is waiting for you in its terminal. Open the session in Terminal to answer.""#
        func hook(_ event: String) -> [String: Any] {
            let fallback = ClaudeHookClient.denied(event: event, reason: "The Rota hook helper is unavailable.")
            let json = (try? JSONSerialization.data(withJSONObject: fallback)).map(lossyUTF8) ?? "{}"
            let command = #""$ROTA_CLI" claude-hook "# + event + " || printf '%s\n' " + shellQuote(json)
            return ["type": "command", "command": command, "timeout": Int(ClaudeHookClient.timeout) + 5]
        }
        let settings: [String: Any] = ["hooks": [
            "PreToolUse": [["matcher": "AskUserQuestion", "hooks": [hook("PreToolUse")]]],
            "PermissionRequest": [["hooks": [hook("PermissionRequest")]]],
            "Notification": [[
            "matcher": "permission_prompt|elicitation_dialog",
            "hooks": [["type": "command", "command": command]]
        ]]]]
        let file = folder.appendingPathComponent(session + "-" + UUID().uuidString + "-settings.json")
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        return file
    }

    private func launch(settings: URL, folder: URL) throws {
        settingsFile = settings
        let arguments = Self.arguments(session: session, resume: spec.resume != nil, settings: settings.path,
                                       model: spec.modelFlags(effortFlag: "--effort"))
        if let existing = Self.transcriptFile(session) {
            transcript = existing
            offset = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.size] as? UInt64) ?? 0
        }
        var environment = ProcessLauncher.baseEnvironment().merging(spec.environment) { $1 }
        environment["TERM"] = "xterm-256color"
        environment["ROTA_CLAUDE_HOOK_SOCKET"] = hookServer?.path
        let process = try PTYProcess(executable: "/bin/zsh", arguments: ["-lc", "exec \"$0\" \"$@\"",
                                    spec.executable] + arguments,
                                    directory: spec.workingDirectory, environment: environment, queue: queue)
        do {
            let terminal = try PTYTerminal(process: process, queue: queue, folder: folder)
            self.terminal = terminal
            process.output = { [weak self, weak terminal] data in
                terminal?.publish(data)
                self?.enterInitialPrompt(after: data)
            }
        } catch {
            process.terminate()
            process.start()
            throw error
        }
        self.process = process
        process.inputFailed = { [weak self] in
            self?.end(as: .launchFailed("Could not write to Claude's terminal."))
        }
        process.exited = { [weak self] status in self?.finish(status: status) }
        process.start()
        journal.session(session)
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.initialPromptWritten else { return }
            self.end(as: .launchFailed("Claude did not show its empty chat field. "
                + "Open Claude Code in this folder to finish its setup, then try again."))
        }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(as: .timedOut) }
        }
        queue.async { self.poll() }
    }

    private func enterInitialPrompt(after data: Data) {
        guard !initialPromptWritten, stopReason == nil, startup.receive(data) else { return }
        initialPromptWritten = true
        startup = ClaudePromptEntry()
        let prompt = spec.chatMessage.fileReferenceText
        guard type("\u{1B}[200~" + prompt + "\u{1B}[201~\r", completed: {
            self.journal.delivery(self.spec.messageID, .written)
        }) else {
            journal.delivery(spec.messageID, .failed("Could not write to Claude's terminal."))
            return end(as: .launchFailed("Could not write the initial message to Claude's terminal."))
        }
    }

    /// Claude's transcript of `session`, in whichever project folder it keeps it.
    static func transcriptFile(_ session: String,
                               projects: URL = FileManager.default.homeDirectoryForCurrentUser
                                   .appendingPathComponent(".claude/projects")) -> URL? {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent("\(session).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func send(_ message: String) { send(message, id: UUID().uuidString) }

    func send(_ message: String, id: String) { send(ChatMessage(text: message), id: id) }

    func send(_ message: ChatMessage, id: String) {
        queue.async {
            self.journal.user(message, id: id)
            guard !self.journal.isFinished, !self.exiting else {
                return self.journal.delivery(id, .failed("The session is ending."))
            }
            if self.promptPending {
                self.startupMessages.append((message, id))
            } else {
                self.deliver(message, id: id)
            }
        }
    }

    private func deliver(_ message: ChatMessage, id: String) {
        let ended = turnEnded
        unanswered += 1
        turnEnded = false
        if !type("\u{1B}[200~" + message.fileReferenceText + "\u{1B}[201~\r", completed: {
            self.journal.delivery(id, .written)
        }) {
            unanswered -= 1
            turnEnded = ended
            journal.delivery(id, .failed("Could not write to Claude's terminal."))
        }
    }

    func respond(_ id: String, response: SessionResponse) {
        queue.async { _ = self.requests.answer(id, response) }
    }

    private func hook(_ id: String, payload: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let event = payload["hook_event_name"] as? String ?? "PermissionRequest"
        guard !journal.isFinished, stopReason == nil, var hook = ClaudeHookRequest(payload, session: session) else {
            let reason = "This request does not belong to a live Rota session."
            return reply(ClaudeHookClient.denied(event: event, reason: reason))
        }
        hook.request.id = id
        requests.add(hook.request, answer: { response in reply(hook.answer(response)) }, cancel: {
            reply(ClaudeHookClient.denied(event: event, reason: "The Rota session has ended."))
        })
    }

    func stop() {
        queue.async { self.end(as: .cancelled) }
    }

    // MARK: On `queue`

    private func poll() {
        guard !journal.isFinished else { return }
        readTranscript()
        if !promptPending, stopReason == nil, !exiting {
            let waiting = startupMessages
            startupMessages.removeAll()
            for (message, id) in waiting { deliver(message, id: id) }
        }
        if turnEnded, unanswered == 0, requests.isEmpty, !exiting, stopReason == nil {
            exiting = true
            type("/exit")
            type("\r")
            // Claude normally leaves at once; a session stuck in a dialog is closed.
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.process?.terminate() }
            queue.asyncAfter(deadline: .now() + 20) { [weak self] in self?.process?.forceKill() }
        }
        // Strong on purpose: the run keeps itself alive until Claude exits.
        queue.asyncAfter(deadline: .now() + 1) { self.poll() }
    }

    private func readTranscript() {
        if transcript == nil { transcript = Self.transcriptFile(session) }
        guard let transcript, let handle = try? FileHandle(forReadingFrom: transcript) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        partial.append(data)
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            self.handle(entry: Data(line))
        }
    }

    private func consumeEvents(_ data: Data) {
        if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for payload in mapper.events(event) { journal.event(payload) }
        }
    }

    private func handle(entry data: Data) {
        consumeEvents(data)
        switch ClaudeTranscript.read(data) {
        case .user(let text):
            journal.confirmUser(text)
            if promptPending, text.trimmingCharacters(in: .whitespacesAndNewlines)
                == spec.chatMessage.fileReferenceText.trimmingCharacters(in: .whitespacesAndNewlines) {
                promptPending = false
                return
            }
            promptPending = false
            unanswered = max(0, unanswered - 1)
            turnEnded = false
            journal.line(Transcript.userLines(text), structured: false)
        case .queued(let text):
            journal.confirmUser(text, queued: true)
            unanswered = max(0, unanswered - 1)
            journal.line(Transcript.userLines(text), structured: false)
        case .assistant(let model, let text):
            if !headerWritten, let model {
                headerWritten = true
                journal.line("[session started, \(model)]", structured: false)
            }
            if let text { journal.line(text, structured: false) }
        case .apiError(let text):
            failed = true
            journal.line("[error] \(text)")
        case .turnEnded:
            turnEnded = true
        case .other:
            break
        }
    }

    @discardableResult
    private func type(_ text: String, completed: (() -> Void)? = nil) -> Bool {
        let completed = UncheckedSendable(completed)
        return process?.write(Data(text.utf8), completed: { [weak self] in
            self?.queue.async { completed.value?() }
        }) ?? false
    }

    private func end(as reason: RunOutcome) {
        guard !journal.isFinished, stopReason == nil else { return }
        stopReason = reason
        requests.cancelAll()
        // Escape interrupts the turn; then the session closes, its transcript saved as it went.
        type("\u{1B}")
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.process?.terminate() }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.process?.forceKill() }
    }

    private func finish(status: Int32) {
        readTranscript()
        let outcome: RunOutcome
        if let stopReason {
            outcome = stopReason
        } else if failed {
            outcome = .failed(exitCode: 1)
        } else if exiting {
            outcome = .succeeded
        } else {
            // Claude left before its work was done: a crash, or it refused to start.
            outcome = status == 0 ? .interrupted : .failed(exitCode: status)
        }
        requests.cancelAll()
        hookServer?.close()
        hookServer = nil
        if let settingsFile { try? FileManager.default.removeItem(at: settingsFile) }
        journal.finish(outcome)
        Self.log.info("interactive claude \(self.session, privacy: .public) ended: \(outcome.title, privacy: .public)")
        terminal?.close()
        terminal = nil
    }
}

/// Recognizes the CLI's empty chat editor, never an authentication or trust choice.
/// Retains split UTF-8 and ANSI sequences across reads. Unexpected renderers fail closed.
struct ClaudePromptEntry {
    private var buffer = Data()

    mutating func receive(_ data: Data) -> Bool {
        buffer.append(data)
        if buffer.count > 65_536 { buffer.removeFirst(buffer.count - 65_536) }
        let terminal = lossyUTF8(buffer)
        let text = terminal.replacingOccurrences(
            of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        // New sessions suggest a task; resumed editors can be completely blank.
        // Setup choices also use the arrow, so require the editor's two borders
        // and its visible cursor after the CLI has finished drawing the frame.
        guard let shown = terminal.range(of: "\u{1B}[?25h", options: .backwards),
              let hidden = terminal.range(of: "\u{1B}[?25l", options: .backwards),
              shown.lowerBound > hidden.lowerBound else { return false }
        let editor = #"─{5,}[\r\n\s]*❯[\s\u00A0]*(?:Try\s*["“][^\r\n]*)?[\r\n\s]+─{5,}"#
        return text.range(of: editor, options: .regularExpression) != nil
    }
}

/// One entry of Claude's session transcript, as the interactive run reads it.
/// Assistant entries have the stream-json shape `StreamJSONFormatter` reads; a
/// message typed while Claude worked shows up as a `queued_command` attachment
/// rather than a user entry; `system`/`turn_duration` closes a turn.
enum ClaudeTranscript: Equatable {
    private static let pastedContentRegex = try? NSRegularExpression(
        pattern: #"\A\s*<pasted_content id="([^"\r\n]+)">\r?\n([\s\S]*)\r?\n</pasted_content id="\1">\s*\z"#)
    case user(String)
    case queued(String)
    case assistant(model: String?, text: String?)
    case apiError(String)
    case turnEnded
    case other

    static func read(_ data: Data) -> ClaudeTranscript {
        guard let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = entry["type"] as? String else { return .other }
        switch type {
        case "user":
            guard entry["isMeta"] as? Bool != true, let text = userText(entry) else { return .other }
            return .user(text)
        case "attachment":
            guard let attachment = entry["attachment"] as? [String: Any],
                  attachment["type"] as? String == "queued_command",
                  let text = attachment["prompt"] as? String else { return .other }
            return .queued(text)
        case "assistant":
            let message = entry["message"] as? [String: Any]
            if entry["isApiErrorMessage"] as? Bool == true {
                let text = (message?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                return .apiError(text.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude could not answer.")
            }
            let model = (message?["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
            return .assistant(model: model, text: StreamJSONFormatter.format(lossyUTF8(data)))
        case "system" where entry["subtype"] as? String == "turn_duration":
            return .turnEnded
        default:
            return .other
        }
    }

    /// What the user typed, without the tool results and command echoes Claude files under the user role.
    static func userText(_ entry: [String: Any]) -> String? {
        let content = (entry["message"] as? [String: Any])?["content"]
        let text: String
        if let value = content as? String {
            text = value
        } else {
            let parts = (content as? [[String: Any]])?.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String } ?? []
            guard !parts.isEmpty else { return nil }
            text = parts.joined(separator: "\n")
        }
        // Long bracketed pastes are wrapped in the interactive provider transcript.
        // Match the whole envelope and its paired ID before removing provider markup.
        if let regex = pastedContentRegex,
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let body = Range(match.range(at: 2), in: text) {
            return String(text[body])
        }
        return text.hasPrefix("<") ? nil : text
    }
}

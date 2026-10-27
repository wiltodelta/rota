import Foundation
import os

/// A Claude routine run as an interactive `claude`, the way a terminal session
/// runs, inside a detached `screen` session that gives it a terminal. Print mode
/// (`claude -p`, `ClaudeStreamRun`) never loads Claude's built-in computer use;
/// an interactive session does, where the user turned it on.
///
/// The chat comes from Claude's own transcript
/// (`~/.claude/projects/<folder>/<session>.jsonl`): its assistant entries have
/// the stream-json shape `StreamJSONFormatter` reads, and a
/// `system`/`turn_duration` entry marks the end of a turn. Messages are typed
/// into the terminal as a bracketed paste, so a line break stays a line break.
/// Once the last turn has ended with no message waiting and no background task
/// running, the run types `/exit`: Claude starts a turn of its own when a task
/// it left running finishes, and leaving earlier would stop that task.
/// "Open in Terminal" attaches to the screen session. A dialog Claude draws there
/// that no hook answers reaches the chat: its `Notification` hook names the
/// dialog file, the run reads the options off the screen (`ClaudeDialog`) and
/// types the chosen option's number.
final class ClaudeInteractiveRun: RunControl, @unchecked Sendable {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "claude")

    private let spec: LaunchSpec
    private let journal: RunJournal
    private let session: String
    private let name: String
    private let exitFile: URL
    private let script: URL
    private let effortFile: URL
    private var settingsFile: URL?
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.claude-interactive")
    private var transcript: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    /// The prompt is in the log already; its transcript entry is skipped once.
    private var promptPending = true
    /// Messages typed in and not yet seen in the transcript.
    private var unanswered = 0
    private var turnEnded = false
    /// Background shells and agents started in this run and not yet reported finished.
    private var background: Set<String> = []
    private var failed = false
    private var exiting = false
    private var stopReason: RunOutcome?
    private var stopping: [OwnedProcess] = []
    private var headerWritten = false
    private let dialogs: ClaudeDialogBridge

    init(spec: LaunchSpec, journal: RunJournal, session: String, folder: URL) {
        self.spec = spec
        self.journal = journal
        self.session = session
        name = Self.screenName(session)
        exitFile = folder.appendingPathComponent("\(name).exit")
        script = folder.appendingPathComponent("\(name).zsh")
        effortFile = folder.appendingPathComponent("\(name)-\(UUID().uuidString).effort")
        dialogs = ClaudeDialogBridge(screen: name, session: session, folder: folder, journal: journal, queue: queue)
    }

    var attachCommand: [String]? { [ScreenRun.screen, "-r", name] }

    static func screenName(_ session: String) -> String { "rota-claude-" + session.prefix(8).lowercased() }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> ClaudeInteractiveRun {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/screen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = spec.resume ?? UUID().uuidString.lowercased()
        let run = ClaudeInteractiveRun(spec: spec, journal: journal, session: session, folder: folder)
        if spec.adopt {
            run.queue.async { run.adopt() }
            return run
        }
        let settings = try ClaudeRunSettings.hooks(in: folder)
        run.settingsFile = settings
        run.queue.async {
            do {
                if let resolved = ClaudeConfiguration.read(executable: spec.executable,
                    directory: spec.workingDirectory, model: spec.model, effort: spec.effort, resume: spec.resume) {
                    journal.configure(resolved.session)
                }
                try run.launch(settings: settings)
            } catch {
                run.cleanUp()
                journal.finish(.launchFailed(error.localizedDescription))
            }
        }
        return run
    }

    /// The `claude` arguments: a new session under `session`, or the resumed one,
    /// then the prompt after `--`, so a prompt starting with a dash stays a prompt.
    static func arguments(session: String, resume: Bool, settings: String, model: [String],
                          prompt: String) -> [String] {
        [resume ? "--resume" : "--session-id", session, "--settings", settings,
         "--permission-mode", "bypassPermissions"] + model + ["--", prompt]
    }

    static func scriptText(executable: String, arguments: [String], directory: String, exitFile: URL) -> String {
        """
        cd \(shellQuote(directory)) || { print -r -- 1 > \(shellQuote(exitFile.path)); exit 1 }
        \(([executable] + arguments).map(shellQuote).joined(separator: " "))
        print -r -- $? > \(shellQuote(exitFile.path))
        """
    }

    private func launch(settings: URL) throws {
        let arguments = Self.arguments(session: session, resume: spec.resume != nil, settings: settings.path,
                                       model: spec.modelFlags(effortFlag: "--effort"), prompt: spec.prompt)
        try Self.scriptText(executable: spec.executable, arguments: arguments, directory: spec.workingDirectory,
                            exitFile: exitFile).write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: exitFile)
        dialogs.cleanUp()
        // A continued session appends to its transcript: read from where it ends now.
        if let existing = Self.transcriptFile(session) {
            transcript = existing
            offset = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.size] as? UInt64) ?? 0
        }
        var environment = spec.environment
        environment["ROTA_SESSION_EFFORT"] = effortFile.path
        environment["ROTA_SESSION_DIALOG"] = dialogs.file.path
        let process = ProcessLauncher.loginShellProcess(ScreenRun.screen, ["-dmS", name, "/bin/zsh", "-l", script.path],
                                                        in: spec.workingDirectory, environment: environment)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LaunchError.screenFailed(process.terminationStatus) }
        journal.session(session)
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(as: .timedOut) }
        }
        queue.async { self.poll() }
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

    func send(_ message: String) {
        queue.async {
            guard !self.journal.isFinished, !self.exiting else { return self.journal.undelivered(message) }
            self.unanswered += 1
            self.turnEnded = false
            self.type("\u{1B}[200~" + message + "\u{1B}[201~")
            self.type("\r")
        }
    }

    func stop() {
        queue.async { self.end(as: .cancelled) }
    }

    // MARK: On `queue`

    private func poll() {
        guard !journal.isFinished else { return }
        readEffort()
        readTranscript()
        dialogs.poll()
        if !stopping.contains(where: { $0.exists }),
           let status = exitStatus ?? (isAlive() ? nil : exitStatus ?? -1) {
            return finish(status: status)
        }
        if turnEnded, unanswered == 0, background.isEmpty, !exiting, stopReason == nil {
            exiting = true
            type("/exit")
            type("\r")
            // Claude normally leaves at once; a session stuck in a dialog is closed.
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.quitScreen() }
        }
        // Strong on purpose: the run keeps itself alive until Claude exits.
        queue.asyncAfter(deadline: .now() + 1) { self.poll() }
    }

    private func readEffort() {
        guard let value = try? String(contentsOf: effortFile, encoding: .utf8) else { return }
        let effort = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["low", "medium", "high", "xhigh", "max"].contains(effort) else { return }
        journal.configure(SessionConfiguration(effort: effort))
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

    /// Takes over a session whose screen outlived Rota: what the transcript holds up to the
    /// log's last write only rebuilds the run's state; everything after it reaches the chat.
    private func adopt() {
        guard let file = spec.terminalTranscript, let data = try? Data(contentsOf: file, options: .alwaysMapped) else {
            return journal.finish(.interrupted)
        }
        transcript = file
        promptPending = false
        headerWritten = true
        let since = (try? FileManager.default.attributesOfItem(atPath: spec.log.path)[.modificationDate]) as? Date
        var start = data.startIndex
        while let since, let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")),
              let entry = (try? JSONSerialization.jsonObject(with: data[start..<newline])) as? [String: Any],
              let written = ClaudeTranscript.timestamp(entry), written <= since {
            restore(ClaudeTranscript.read(entry: entry))
            dialogs.track(entry, movesOn: false)
            start = data.index(after: newline)
        }
        offset = UInt64(start - data.startIndex)
        journal.session(session)
        journal.record(.status, "Following the session Claude kept running while Rota was closed")
        dialogs.adopt()
        queue.async { self.poll() }
    }

    /// The state an entry leaves behind, without recording it again.
    private func restore(_ entry: ClaudeTranscript) {
        switch entry {
        case .user, .queued: turnEnded = false
        case .service(let text):
            let tasks = TranscriptService.taskIDs(text)
            // A task notification is Claude's next prompt: a turn follows it.
            if !tasks.isEmpty { turnEnded = false }
            background.subtract(tasks)
        case .background(let id, let running):
            if running { background.insert(id) } else { background.remove(id) }
        case .turnEnded: turnEnded = true
        case .assistant, .apiError: turnEnded = false
        case .other: break
        }
    }

    /// The entry's state (as `restore`), then what reaches the chat.
    func handle(entry data: Data) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let entry = object.map(ClaudeTranscript.read(entry:)) ?? .other
        restore(entry)
        if let object { dialogs.track(object, movesOn: entry.movesOn) }
        record(entry, data: data)
    }

    private func record(_ entry: ClaudeTranscript, data: Data) {
        switch entry {
        case .user(let text):
            if promptPending, text.trimmingCharacters(in: .whitespacesAndNewlines)
                == spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                promptPending = false
                return
            }
            promptPending = false
            unanswered = max(0, unanswered - 1)
            journal.record(.user, text)
        case .queued(let text):
            unanswered = max(0, unanswered - 1)
            journal.record(.user, text)
        case .assistant(let model, let items):
            assistant(model: model, items: items)
        case .service(let text):
            journal.record(.status, text)
        case .apiError(let text):
            failed = true
            journal.line("[error] \(text)")
        case .turnEnded:
            if !background.isEmpty { journal.record(.status, TranscriptService.waiting(background.count)) }
        case .background, .other:
            for item in StreamJSONFormatter.items(data) { journal.record(item.kind, item.text) }
        }
    }

    private func assistant(model: String?, items: [TranscriptItem]) {
        if !items.isEmpty { failed = false }
        journal.configure(SessionConfiguration(model: model))
        if !headerWritten, let model {
            headerWritten = true
            journal.line("[session started, \(model)]")
        }
        for item in items { journal.record(item.kind, item.text) }
    }

    private var exitStatus: Int32? {
        guard let text = try? String(contentsOf: exitFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isAlive() -> Bool { ScreenRun.alive(name) }

    private func type(_ text: String) { ScreenRun.type(name, text) }

    private func quitScreen() { ScreenRun.quit(name) }

    private func end(as reason: RunOutcome) {
        guard !journal.isFinished, stopReason == nil else { return }
        stopReason = reason
        if let pid = ScreenRun.pid(name), let root = OwnedProcess(pid: pid) {
            stopping = root.descendants() + [root]
        }
        // Escape interrupts the turn; then the session closes, its transcript saved as it went.
        type("\u{1B}")
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.quitScreen() }
        let owned = stopping
        queue.asyncAfter(deadline: .now() + 3) { for child in owned { child.signal(SIGTERM) } }
        queue.asyncAfter(deadline: .now() + 10) { for child in owned { child.signal(SIGKILL) } }
    }

    func finish(status: Int32) {
        readEffort()
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
        journal.finish(outcome)
        Self.log.info("interactive claude \(self.session, privacy: .public) ended: \(outcome.title, privacy: .public)")
        cleanUp()
    }

    private func cleanUp() {
        dialogs.cleanUp()
        for file in [exitFile, script, effortFile] + (settingsFile.map { [$0] } ?? []) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// One entry of Claude's session transcript, as the interactive run reads it.
/// Assistant entries have the stream-json shape `StreamJSONFormatter` reads; a
/// message typed while Claude worked shows up as a `queued_command` attachment
/// rather than a user entry; `system`/`turn_duration` closes a turn. A
/// background shell or agent starts with a tool result naming its id and ends
/// with a task notification naming it, or with a `TaskStop` result, which sends none.
enum ClaudeTranscript: Equatable {
    case user(String)
    case queued(String)
    case service(String)
    /// A background task by id: started (`running`), or stopped by `TaskStop`.
    case background(String, running: Bool)
    case assistant(model: String?, items: [TranscriptItem])
    case apiError(String)
    case turnEnded
    case other

    /// A tool call an assistant entry starts, with the input Claude gave it.
    struct ToolCall {
        var id: String
        var name: String
        var input: [String: Any]
    }

    /// The tool calls `entry` starts (`tool_use` blocks) and the ids it answers (`tool_result` blocks).
    static func toolCalls(_ entry: [String: Any]) -> (started: [ToolCall], ended: [String]) {
        let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch entry["type"] as? String {
        case "assistant":
            return (blocks.compactMap { block in
                guard block["type"] as? String == "tool_use", let id = block["id"] as? String,
                      let name = block["name"] as? String else { return nil }
                return ToolCall(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])
            }, [])
        case "user":
            return ([], blocks.filter { $0["type"] as? String == "tool_result" }
                .compactMap { $0["tool_use_id"] as? String })
        default:
            return ([], [])
        }
    }

    /// Whether Claude went on past a dialog: a message, an answer or the turn's end.
    var movesOn: Bool {
        switch self {
        case .user, .queued, .assistant, .turnEnded: return true
        case .service, .background, .apiError, .other: return false
        }
    }

    /// When Claude wrote the entry.
    static func timestamp(_ entry: [String: Any]) -> Date? {
        guard let text = entry["timestamp"] as? String else { return nil }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func read(_ data: Data) -> ClaudeTranscript {
        guard let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .other }
        return read(entry: entry)
    }

    static func read(entry: [String: Any]) -> ClaudeTranscript {
        guard let type = entry["type"] as? String else { return .other }
        switch type {
        case "user": return backgroundTask(entry["toolUseResult"]) ?? userEntry(entry)
        case "attachment":
            guard let attachment = entry["attachment"] as? [String: Any],
                  attachment["type"] as? String == "queued_command",
                  let text = attachment["prompt"] as? String else { return .other }
            // A notification arriving mid-turn is queued like a message, but nobody typed it.
            return TranscriptService.title(text) == nil ? .queued(text) : .service(text)
        case "assistant":
            let message = entry["message"] as? [String: Any]
            if entry["isApiErrorMessage"] as? Bool == true {
                let text = (message?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                return .apiError(text.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude could not answer.")
            }
            let model = (message?["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
            return .assistant(model: model, items: StreamJSONFormatter.assistantItems(entry))
        case "system" where entry["subtype"] as? String == "turn_duration":
            return .turnEnded
        default:
            return .other
        }
    }

    private static func backgroundTask(_ result: Any?) -> ClaudeTranscript? {
        guard let result = result as? [String: Any] else { return nil }
        if let id = result["backgroundTaskId"] as? String { return .background(id, running: true) }
        if result["status"] as? String == "async_launched", let id = result["agentId"] as? String {
            return .background(id, running: true)
        }
        // Only a `TaskStop` result has this shape (14 of 14 in transcripts read on 2026-10-26).
        if let id = result["task_id"] as? String, result["task_type"] is String {
            return .background(id, running: false)
        }
        return nil
    }

    private static func userEntry(_ entry: [String: Any]) -> ClaudeTranscript {
        guard entry["isMeta"] as? Bool != true, let text = userText(entry) else { return .other }
        if TranscriptService.title(text) != nil { return .service(text) }
        if text.hasPrefix("<command-name>") { return .other }
        return .user(text)
    }

    /// What the user typed, without the tool results and command echoes Claude files under the user role.
    static func userText(_ entry: [String: Any]) -> String? {
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String { return text }
        let parts = (content as? [[String: Any]])?.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String } ?? []
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

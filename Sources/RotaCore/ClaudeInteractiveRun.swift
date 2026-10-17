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
/// Once the last turn has ended with no message waiting, the run types `/exit`.
/// "Open in Terminal" attaches to the screen session, where the user can answer
/// whatever Claude asks there; a `Notification` hook marks the session
/// needs-reply when Claude waits for that.
final class ClaudeInteractiveRun: RunControl, @unchecked Sendable {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "claude")

    private let spec: LaunchSpec
    private let journal: RunJournal
    private let session: String
    private let name: String
    private let exitFile: URL
    private let script: URL
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.claude-interactive")
    private var transcript: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    /// The prompt is in the log already; its transcript entry is skipped once.
    private var promptPending = true
    /// Messages typed in and not yet seen in the transcript.
    private var unanswered = 0
    private var turnEnded = false
    private var failed = false
    private var exiting = false
    private var stopReason: RunOutcome?
    private var headerWritten = false

    private init(spec: LaunchSpec, journal: RunJournal, session: String, folder: URL) {
        self.spec = spec
        self.journal = journal
        self.session = session
        name = Self.screenName(session)
        exitFile = folder.appendingPathComponent("\(name).exit")
        script = folder.appendingPathComponent("\(name).zsh")
    }

    var attachCommand: [String]? { [ScreenRun.screen, "-r", name] }

    static func screenName(_ session: String) -> String { "rota-claude-" + session.prefix(8).lowercased() }

    /// Whether a screen session of that name is still up.
    static func alive(_ name: String) -> Bool {
        let (_, output) = ProcessLauncher.capture(ScreenRun.screen, ["-ls", name], in: NSTemporaryDirectory(),
                                                  loginShell: false)
        return output.contains(".\(name)")
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> ClaudeInteractiveRun {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/screen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = spec.resume ?? UUID().uuidString.lowercased()
        let run = ClaudeInteractiveRun(spec: spec, journal: journal, session: session, folder: folder)
        try run.launch(settings: try hookSettings(in: folder))
        return run
    }

    /// The `claude` arguments: a new session under `session`, or the resumed one,
    /// then the prompt after `--`, so a prompt starting with a dash stays a prompt.
    static func arguments(session: String, resume: Bool, settings: String, model: [String],
                          prompt: String) -> [String] {
        [resume ? "--resume" : "--session-id", session, "--settings", settings,
         "--permission-mode", "bypassPermissions"] + model + ["--", prompt]
    }

    /// Settings Rota adds to the user's for its runs: when Claude waits for the
    /// user in its terminal (a permission or an app it asks to use), the
    /// session is marked needs-reply through the `rota` command the run carries.
    static func hookSettings(in folder: URL) throws -> URL {
        let command = #"[ -n "$ROTA_CLI" ] && "$ROTA_CLI" notify --needs-reply "#
            + #""Claude is waiting for you in its terminal. Open the session in Terminal to answer.""#
        let settings: [String: Any] = ["hooks": ["Notification": [[
            "matcher": "permission_prompt|elicitation_dialog",
            "hooks": [["type": "command", "command": command]]
        ]]]]
        let file = folder.appendingPathComponent("claude-settings.json")
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        return file
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
        // A continued session appends to its transcript: read from where it ends now.
        if let existing = Self.transcriptFile(session) {
            transcript = existing
            offset = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.size] as? UInt64) ?? 0
        }
        let process = ProcessLauncher.loginShellProcess(ScreenRun.screen, ["-dmS", name, "/bin/zsh", "-l", script.path],
                                                        in: spec.workingDirectory, environment: spec.environment)
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
            guard !self.journal.isFinished, !self.exiting else {
                return self.journal.line("[rota: message not delivered: the session is ending]")
            }
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
        readTranscript()
        if let status = exitStatus ?? (isAlive() ? nil : exitStatus ?? -1) {
            return finish(status: status)
        }
        if turnEnded, unanswered == 0, !exiting, stopReason == nil {
            exiting = true
            type("/exit")
            type("\r")
            // Claude normally leaves at once; a session stuck in a dialog is closed.
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.quitScreen() }
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

    private func handle(entry data: Data) {
        switch ClaudeTranscript.read(data) {
        case .user(let text):
            if promptPending, text.trimmingCharacters(in: .whitespacesAndNewlines)
                == spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                promptPending = false
                return
            }
            promptPending = false
            unanswered = max(0, unanswered - 1)
            turnEnded = false
            journal.record(.user, text)
        case .queued(let text):
            unanswered = max(0, unanswered - 1)
            journal.record(.user, text)
        case .assistant(let model, let items):
            journal.configure(SessionConfiguration(model: model))
            if !headerWritten, let model {
                headerWritten = true
                journal.line("[session started, \(model)]")
            }
            for item in items { journal.record(item.kind, item.text) }
        case .apiError(let text):
            failed = true
            journal.line("[error] \(text)")
        case .turnEnded:
            turnEnded = true
        case .other:
            break
        }
    }

    private var exitStatus: Int32? {
        guard let text = try? String(contentsOf: exitFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isAlive() -> Bool { Self.alive(name) }

    private func type(_ text: String) {
        _ = ProcessLauncher.capture(ScreenRun.screen, ["-S", name, "-p", "0", "-X", "stuff", text],
                                    in: NSTemporaryDirectory(), loginShell: false)
    }

    private func quitScreen() {
        _ = ProcessLauncher.capture(ScreenRun.screen, ["-S", name, "-X", "quit"], in: NSTemporaryDirectory(),
                                    loginShell: false)
    }

    private func end(as reason: RunOutcome) {
        guard !journal.isFinished, stopReason == nil else { return }
        stopReason = reason
        // Escape interrupts the turn; then the session closes, its transcript saved as it went.
        type("\u{1B}")
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.quitScreen() }
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
        journal.finish(outcome)
        Self.log.info("interactive claude \(self.session, privacy: .public) ended: \(outcome.title, privacy: .public)")
        try? FileManager.default.removeItem(at: exitFile)
        try? FileManager.default.removeItem(at: script)
    }
}

/// One entry of Claude's session transcript, as the interactive run reads it.
/// Assistant entries have the stream-json shape `StreamJSONFormatter` reads; a
/// message typed while Claude worked shows up as a `queued_command` attachment
/// rather than a user entry; `system`/`turn_duration` closes a turn.
enum ClaudeTranscript: Equatable {
    case user(String)
    case queued(String)
    case assistant(model: String?, items: [TranscriptItem])
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
            return .assistant(model: model, items: StreamJSONFormatter.assistantItems(entry))
        case "system" where entry["subtype"] as? String == "turn_duration":
            return .turnEnded
        default:
            return .other
        }
    }

    /// What the user typed, without the tool results and command echoes Claude files under the user role.
    static func userText(_ entry: [String: Any]) -> String? {
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String { return text.hasPrefix("<") ? nil : text }
        let parts = (content as? [[String: Any]])?.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String } ?? []
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

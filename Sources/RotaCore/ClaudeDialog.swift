import Foundation
import os

/// A dialog an interactive Claude draws in its terminal that no hook answers, such as computer
/// use's app-access request or a paused session's choice, read off the `screen` session so the
/// chat can show it and answer it with the option's number key, as a user at the terminal would
/// (a digit picks the option in Claude Code 2.1.311, checked 2026-10-27).
///
/// `screen` 4.00.03's hardcopy is 8-bit: ASCII survives, any other character keeps only its
/// low byte, so `─` reads as a blank and `╌` as `L` (checked 2026-10-27, `-U` or not). Claude's
/// own labels are ASCII; a non-ASCII name inside one can read wrong, so what Claude asks to do
/// comes from its transcript instead (`tool`).
struct ClaudeDialog: Equatable {
    /// The lines just above the options, such as "Do you want to proceed?".
    var prompt: [String]
    var options: [String]

    /// The dialog at the bottom of the screen: a run of options numbered from 1, exactly one
    /// marked as selected, followed by no more than a footer. A numbered list in Claude's
    /// answer has no selection marker, and the input box follows it.
    static func read(screen data: Data) -> ClaudeDialog? {
        let printable = data.map { (0x20...0x7E).contains($0) || $0 == 0x0A ? $0 : 0x20 }
        let text = String(bytes: printable, encoding: .ascii) ?? ""
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        var found: ClaudeDialog?
        var index = 0
        while index < lines.count {
            guard let first = Option(lines[index]), first.number == 1 else {
                index += 1
                continue
            }
            var options = [first.label]
            var marked = first.marked ? 1 : 0
            var next = index + 1
            while next < lines.count {
                let line = lines[next]
                if let option = Option(line) {
                    guard option.number == options.count + 1 else { break }
                    options.append(option.label)
                    marked += option.marked ? 1 : 0
                } else if !line.isEmpty, line.prefix(while: { $0 == " " }).count >= first.labelColumn {
                    options[options.count - 1] += " " + collapsed(line)
                } else {
                    break
                }
                next += 1
            }
            let footer = lines[next...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if options.count >= 2, marked == 1, footer.count <= 3 {
                found = ClaudeDialog(prompt: prompt(above: index, in: lines), options: options)
            }
            index = next
        }
        return found
    }

    /// Up to three lines above the options, stopping at a blank line or a drawn rule.
    private static func prompt(above index: Int, in lines: [String]) -> [String] {
        var prompt: [String] = []
        for line in lines[..<index].reversed() {
            let text = collapsed(line)
            if text.isEmpty || Set(text).count == 1 && text.count >= 10 || prompt.count == 3 { break }
            prompt.insert(text, at: 0)
        }
        return prompt
    }

    private static func collapsed(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// A line such as `❯ 1. Yes` (the marker reads as `o`) or `  2. No`.
    private struct Option {
        var number: Int
        var label: String
        var marked: Bool
        var labelColumn: Int

        init?(_ line: String) {
            guard let match = line.firstMatch(of: /^(\s*)(?:(\S)\s+)?([1-9])\.\s+(\S.*)$/),
                  let number = Int(match.3) else { return nil }
            self.number = number
            label = ClaudeDialog.collapsed(String(match.4))
            marked = match.2 != nil
            labelColumn = line.distance(from: line.startIndex, to: match.4.startIndex)
        }
    }

    static let defaultTitle = "Claude is waiting for your answer"
    /// Escape cancels a Claude dialog.
    static let escape = "\u{1B}"

    static func cancels(_ action: String) -> Bool { action == "cancel" || action == "decline" }

    /// The chat's form: one action per option, labeled as Claude labels it. A dialog
    /// whose options could not be read (nil) can only be canceled from the chat.
    static func question(for dialog: ClaudeDialog?, title: String, tool: String?) -> AgentQuestion {
        let unreadable = "Rota cannot read the choices of this dialog. Open the session in Terminal to answer it, "
            + "or cancel it here."
        let parts = [dialog.map { $0.prompt.joined(separator: " ") }, tool, dialog == nil ? unreadable : nil]
        return AgentQuestion(title: title, detail: parts.compactMap { $0 }.filter { !$0.isEmpty }
                                .joined(separator: "\n\n"),
                             actions: (dialog?.options ?? []).map { QuestionOption(id: $0, label: $0) })
    }

    /// What to type for `action`: the option's number, or Escape.
    func key(for action: String) -> String? {
        if Self.cancels(action) { return Self.escape }
        return options.firstIndex(of: action).map { String($0 + 1) }
    }
}

extension ClaudeDialog {
    /// One line of a run's dialog file (`ROTA_SESSION_DIALOG`).
    enum Event: Equatable {
        /// Claude's `Notification` payload: a dialog opened.
        case shown(message: String?)
        /// `rota question-hook` (process `pid`) started or stopped waiting for the chat.
        case question(pid: Int32, open: Bool)
    }

    static func event(_ line: some StringProtocol) -> Event? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return nil
        }
        if let state = object["rota_question"] as? String, let pid = object["pid"] as? Int {
            return .question(pid: Int32(pid), open: state == "open")
        }
        guard object["hook_event_name"] as? String == "Notification" else { return nil }
        return .shown(message: object["message"] as? String)
    }

    /// Appends to the dialog file at `path`, if the run names one, in one `write` with
    /// `O_APPEND`, so lines from Claude's hooks never interleave.
    static func appendQuestionMarker(open: Bool, to path: String?) {
        guard let path else { return }
        let marker: [String: Any] = ["rota_question": open ? "open" : "closed", "pid": Int(getpid())]
        guard let data = try? JSONSerialization.data(withJSONObject: marker) else { return }
        let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let line = data + Data("\n".utf8)
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}

/// An interactive run's terminal dialogs in the chat. Its methods run on the run's queue.
/// The dialog file is named by screen session, so a run adopted after a Rota restart
/// reads what Claude's hook still writes.
final class ClaudeDialogBridge: @unchecked Sendable {
    let file: URL
    private let screenFile: URL
    private let screen: String
    private let session: String
    private let journal: RunJournal
    private let queue: DispatchQueue
    private var offset: UInt64 = 0
    /// `rota question-hook` processes waiting for the chat; Claude's dialog for that request is already there.
    private var hookQuestions: Set<Int32> = []
    /// A notification came while a question hook waited: once none waits, the screen is read again,
    /// in case another dialog opened alongside.
    private var notifiedDuringHook = false
    /// The dialog in the chat, and its options as read off the screen (nil: unreadable).
    private var shown: (question: String, dialog: ClaudeDialog?)?
    private var polls = 0
    /// Recent tool calls started and not yet answered, oldest first: what a dialog is most likely about.
    private var pendingTools: [ClaudeTranscript.ToolCall] = []

    init(screen: String, session: String, folder: URL, journal: RunJournal, queue: DispatchQueue) {
        self.screen = screen
        self.session = session
        self.journal = journal
        self.queue = queue
        file = folder.appendingPathComponent("\(screen).dialog")
        screenFile = folder.appendingPathComponent("\(screen).screen")
    }

    private var log: Logger { ClaudeInteractiveRun.log }

    /// Records the tool calls a transcript entry starts and ends. An unreadable dialog has
    /// no screen to watch: Claude moving on (`movesOn`, or a tool answered) closes it.
    func track(_ entry: [String: Any], movesOn: Bool) {
        let calls = ClaudeTranscript.toolCalls(entry)
        pendingTools.removeAll { calls.ended.contains($0.id) }
        // A call interrupted before its result never ends; keep only the latest few inputs.
        pendingTools = Array((pendingTools + calls.started).suffix(8))
        if movesOn || !calls.ended.isEmpty, let shown, shown.dialog == nil { close(shown.question) }
    }

    /// Earlier notifications are history after a Rota restart; a dialog still open is on the screen.
    func adopt() {
        _ = readEvents()
        if hookQuestions.isEmpty, let open = read() { show(open, title: ClaudeDialog.defaultTitle) }
    }

    /// A dialog Claude opened while no question hook waits reaches the chat. A notification
    /// while one waits is that request, already there.
    func poll() {
        polls += 1
        let notified = readEvents()
        if notifiedDuringHook, hookQuestions.isEmpty {
            notifiedDuringHook = false
            if notified == nil, shown == nil, let open = read() { return show(open, title: ClaudeDialog.defaultTitle) }
        }
        guard let notified else { return watch() }
        guard hookQuestions.isEmpty else {
            notifiedDuringHook = true
            return log.info("claude \(self.session, privacy: .public) dialog belongs to a pending question")
        }
        let open = read()
        if let shown {
            if let open, open.options == shown.dialog?.options { return }
            close(shown.question)
        }
        show(open, title: notified)
    }

    func cleanUp() {
        for url in [file, screenFile] { try? FileManager.default.removeItem(at: url) }
    }

    /// New whole lines of the dialog file: question hooks opening and closing, and Claude's
    /// notifications. Returns the last notification's title, nil when there was none.
    private func readEvents() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        // A hook may be halfway through writing the last line.
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        offset += UInt64(end - data.startIndex + 1)
        var notified: String?
        for line in lossyUTF8(data[...end]).split(separator: "\n") {
            switch ClaudeDialog.event(line) {
            case .question(let pid, true)?: hookQuestions.insert(pid)
            case .question(let pid, false)?: hookQuestions.remove(pid)
            case .shown(let message)?: notified = message ?? ClaudeDialog.defaultTitle
            case nil: break
            }
        }
        // A hook Claude canceled never writes its closing line.
        hookQuestions = hookQuestions.filter { kill($0, 0) == 0 }
        return notified
    }

    /// Asks the chat about `open` (nil: a dialog whose options could not be read).
    private func show(_ open: ClaudeDialog?, title: String) {
        let tool = pendingTools.last.map { $0.name + "\n" + QuestionRequest.json($0.input) }
        let question = ClaudeDialog.question(for: open, title: title, tool: tool)
        shown = (question.id, open)
        let options = open?.options.joined(separator: " | ") ?? "unreadable"
        log.info("""
            claude \(self.session, privacy: .public) dialog: \(title, privacy: .public) \(options, privacy: .public)
            """)
        journal.ask(question) { [weak self] answer in
            guard let self else { return }
            queue.async { self.answer(answer, to: question.id) }
        }
    }

    /// While a readable dialog is in the chat, a look every other second notices it
    /// closed, answered at the terminal or left behind by Claude.
    private func watch() {
        guard let shown, let dialog = shown.dialog, polls % 2 == 0 else { return }
        if read()?.options != dialog.options { close(shown.question) }
    }

    private func close(_ question: String) {
        guard shown?.question == question else { return }
        shown = nil
        journal.resolveQuestion(question)
    }

    /// Types the answer into the dialog it was given for, once the screen still shows it.
    private func answer(_ answer: QuestionAnswer, to question: String) {
        guard let current = shown, current.question == question, !journal.isFinished else { return }
        shown = nil
        guard let dialog = current.dialog else {
            if ClaudeDialog.cancels(answer.action) { type(ClaudeDialog.escape) }
            return
        }
        guard read()?.options == dialog.options, let key = dialog.key(for: answer.action) else {
            return journal.record(.status, "Claude's dialog had already closed; Rota typed nothing")
        }
        log.info("claude \(self.session, privacy: .public) dialog answer: \(answer.action, privacy: .public)")
        type(key)
        if !ClaudeDialog.cancels(answer.action) { confirm(dialog) }
    }

    /// An option that also takes text waits for Return after its number.
    private func confirm(_ dialog: ClaudeDialog) {
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.read()?.options == dialog.options else { return }
            self.type("\r")
            self.queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.read()?.options == dialog.options else { return }
                self.journal.record(.status, "Claude did not take the answer; answer it in Terminal")
            }
        }
    }

    private func type(_ text: String) { ScreenRun.type(screen, text) }

    /// The dialog on the screen now, read from a hardcopy of the session's window.
    private func read() -> ClaudeDialog? {
        let manager = FileManager.default
        try? manager.removeItem(at: screenFile)
        defer { try? manager.removeItem(at: screenFile) }
        ScreenRun.command(screen, ["-p", "0", "-X", "hardcopy", screenFile.path])
        // screen writes the copy itself, a moment after the command returns.
        for _ in 0..<10 where !manager.fileExists(atPath: screenFile.path) { usleep(50_000) }
        return (try? Data(contentsOf: screenFile)).flatMap(ClaudeDialog.read(screen:))
    }
}

import Foundation
import os

/// A dialog an interactive Claude draws in its terminal that no hook answers, such as computer
/// use's app-access or macOS-permission request or a paused session's choice, read off the
/// `screen` session so the chat can show it and answer it as a user at the terminal would: a
/// numbered dialog takes the option's digit, and an unnumbered (`hideIndexes`) dialog steps from
/// the focused `❯` row with Up/Down arrows and confirms with Return (Claude Code 2.1.323,
/// checked 2026-11-13).
///
/// `screen` 4.00.03's hardcopy is 8-bit even under `-U`: ASCII survives, any other decoded
/// codepoint keeps only its low byte, so `─` reads as NULs, `╌` as `L`, and `❯` as `o`
/// (checked 2026-11-13; `-U` ensures UTF-8 decoding even when `LANG` is unset).
/// Claude's own labels are ASCII; a non-ASCII name inside one can read wrong, so what Claude asks
/// to do comes from its transcript too (`tool`).
struct ClaudeDialog: Equatable {
    /// The lines above the options, such as "Do you want to proceed?" or the dialog's header and body.
    var prompt: [String]
    var options: [String]
    /// Index in `options` currently marked as focused (`❯`), 0-based.
    var selected = 0
    /// Whether Claude numbered the options (`1.`, `2.`, ...); unnumbered dialogs take arrows and Return.
    var numbered = true

    /// The dialog at the bottom of the screen: a contiguous block of numbered or indented unnumbered
    /// options with exactly one selection marker, followed by no more than a footer. A list in
    /// Claude's answer has no selection marker, and the input box follows it.
    static func read(screen data: Data) -> ClaudeDialog? {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map(ScreenLine.init)
        var found: ClaudeDialog?
        var index = 0
        while index < lines.count {
            if let hit = numberedDialog(at: index, in: lines) ?? unnumberedDialog(at: index, in: lines) {
                if let dialog = hit.dialog { found = dialog }
                index = hit.next
            } else {
                index += 1
            }
        }
        return found
    }

    private static func numberedDialog(at index: Int,
                                       in lines: [ScreenLine]) -> (dialog: ClaudeDialog?, next: Int)? {
        guard let first = lines[index].option, first.number == 1 else { return nil }
        var options = [first.label]
        var marked = first.marked ? 1 : 0
        var selected = 0
        var next = index + 1
        while next < lines.count {
            let line = lines[next]
            if let option = line.option {
                guard option.number == options.count + 1 else { break }
                if option.marked { selected = options.count; marked += 1 }
                options.append(option.label)
            } else if !line.text.isEmpty, line.indent >= first.labelColumn {
                options[options.count - 1] += " " + collapsed(line.text)
            } else {
                break
            }
            next += 1
        }
        guard options.count >= 2, marked == 1, isAtBottom(lines[next...]) else { return (nil, next) }
        let dialog = ClaudeDialog(prompt: prompt(above: index, in: lines), options: options,
                                  selected: selected, numbered: true)
        return (dialog, next)
    }

    private static func unnumberedDialog(at focusIndex: Int,
                                         in lines: [ScreenLine]) -> (dialog: ClaudeDialog?, next: Int)? {
        guard let focused = lines[focusIndex].focused else { return nil }
        func belongs(_ line: ScreenLine) -> Bool {
            !line.text.isEmpty && line.option == nil && (line.focused != nil || line.indent >= focused.labelColumn)
        }
        var start = focusIndex
        while start > 0, belongs(lines[start - 1]) { start -= 1 }
        while start < focusIndex, lines[start].focused == nil, lines[start].indent > focused.labelColumn {
            start += 1
        }
        var next = focusIndex + 1
        while next < lines.count, belongs(lines[next]) { next += 1 }
        var options: [String] = []
        var marked = 0
        var selected = 0
        for row in start..<next {
            if let choice = lines[row].focused {
                selected = options.count
                marked += 1
                options.append(choice.label)
            } else if lines[row].indent == focused.labelColumn {
                options.append(collapsed(lines[row].text))
            } else if !options.isEmpty {
                options[options.count - 1] += " " + collapsed(lines[row].text)
            }
        }
        guard options.count >= 2, marked == 1, isAtBottom(lines[next...]) else { return (nil, next) }
        let dialog = ClaudeDialog(prompt: prompt(above: start, in: lines), options: options,
                                  selected: selected, numbered: false)
        return (dialog, next)
    }

    private static func isAtBottom(_ tail: ArraySlice<ScreenLine>) -> Bool {
        guard tail.filter({ !$0.text.isEmpty }).count <= 3 else { return false }
        if let rule = tail.firstIndex(where: \.isRule) {
            return tail[(rule + 1)...].allSatisfy(\.text.isEmpty)
        }
        return true
    }

    /// The dialog's own lines above the options: indented dialog body lines up to the enclosing
    /// rule or column-0 transcript output, or up to three unindented prompt lines before a gap.
    private static func prompt(above index: Int, in lines: [ScreenLine]) -> [String] {
        var prompt: [String] = []
        var unindented = false
        for line in lines[..<index].reversed() {
            if line.isRule { break }
            if line.text.isEmpty {
                if unindented { break }
                continue
            }
            if line.indent == 0 {
                if !prompt.isEmpty && !unindented { break }
                unindented = true
            }
            prompt.insert(collapsed(line.text), at: 0)
            if prompt.count == (unindented ? 3 : 12) { break }
        }
        return prompt
    }

    private static func collapsed(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private struct ScreenLine {
        let text: String
        let indent: Int
        let isRule: Bool
        let option: Option?
        let focused: FocusedOption?

        init(_ raw: Data.SubSequence) {
            var nuls = 0
            var borderBytes = true
            for byte in raw {
                if byte == 0 { nuls += 1 } else if byte != 0x20, byte != 0x0D { borderBytes = false }
            }
            if borderBytes, nuls >= 10 {
                text = ""; indent = 0; isRule = true; option = nil; focused = nil
                return
            }
            guard let end = raw.lastIndex(where: { (0x21...0x7E).contains($0) }) else {
                text = ""; indent = 0; isRule = false; option = nil; focused = nil
                return
            }
            let trimmed = String(bytes: raw[...end].map { (0x21...0x7E).contains($0) ? $0 : 0x20 },
                                 encoding: .ascii) ?? ""
            let nonSpace = trimmed.drop { $0 == " " }
            if nonSpace.count >= 10, nonSpace.allSatisfy({ $0 == nonSpace.first }) {
                text = ""; indent = 0; isRule = true; option = nil; focused = nil
                return
            }
            text = trimmed
            indent = trimmed.count - nonSpace.count
            isRule = false
            option = Option(trimmed)
            focused = option == nil ? FocusedOption(trimmed) : nil
        }
    }

    /// A numbered line such as `❯ 1. Yes` (the marker reads as `o`) or `  2. No`.
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

    /// A focused unnumbered option row such as `  o Allow for this session (1 app)`.
    private struct FocusedOption {
        var label: String
        var labelColumn: Int

        init?(_ line: String) {
            guard let match = line.firstMatch(of: /^(\s+)([o>])(\s{1,3})(\S.*)$/) else { return nil }
            label = ClaudeDialog.collapsed(String(match.4))
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
        return AgentQuestion(title: title, detail: dialog?.prompt.joined(separator: "\n") ?? unreadable,
                             actions: (dialog?.options ?? []).map { QuestionOption(id: $0, label: $0) },
                             context: tool)
    }

    /// What to type for `action`: the option's digit, Up/Down arrows plus Return, or Escape.
    func key(for action: String) -> String? {
        if Self.cancels(action) { return Self.escape }
        guard let target = options.firstIndex(of: action) else { return nil }
        if numbered { return String(target + 1) }
        let step = target >= selected ? "\u{1B}[B" : "\u{1B}[A"
        return String(repeating: step, count: abs(target - selected)) + "\r"
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
    private let readScreen: (() -> ClaudeDialog?)?
    private let typeKey: ((String) -> Void)?
    private var offset: UInt64 = 0
    /// `rota question-hook` processes waiting for the chat; Claude's dialog for that request is already there.
    private var hookQuestions: Set<Int32> = []
    /// A notification came while a question hook waited: once none waits, the screen is read again,
    /// in case another dialog opened alongside.
    private var notifiedDuringHook = false
    /// The dialog in the chat, and its options as read off the screen (nil: unreadable).
    private struct ShownDialog {
        let question: String
        let dialog: ClaudeDialog?
        let title: String
    }
    private var shown: ShownDialog?
    private var polls = 0
    /// Recent tool calls started and not yet answered, oldest first: what a dialog is most likely about.
    private var pendingTools: [ClaudeTranscript.ToolCall] = []

    init(screen: String, session: String, folder: URL, journal: RunJournal, queue: DispatchQueue,
         readScreen: (() -> ClaudeDialog?)? = nil, typeKey: ((String) -> Void)? = nil) {
        self.screen = screen
        self.session = session
        self.journal = journal
        self.queue = queue
        self.readScreen = readScreen
        self.typeKey = typeKey
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
        shown = ShownDialog(question: question.id, dialog: open, title: title)
        let options = open?.options.joined(separator: " | ") ?? "unreadable"
        log.info("""
            claude \(self.session, privacy: .public) dialog: \(title, privacy: .public) \(options, privacy: .public)
            """)
        journal.ask(question) { [weak self] answer in
            guard let self else { return }
            queue.async { self.answer(answer, to: question.id) }
        }
    }

    /// Retry a notification captured before Claude finished drawing its choices too.
    private func watch() {
        guard let shown, polls % 2 == 0 else { return }
        let open = read()
        if let dialog = shown.dialog {
            if open?.options != dialog.options { close(shown.question) }
        } else if let open {
            close(shown.question)
            show(open, title: shown.title)
        }
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
        guard let live = read(), live.options == dialog.options, let key = live.key(for: answer.action) else {
            return journal.record(.status, "Claude's dialog had already closed; Rota typed nothing")
        }
        log.info("claude \(self.session, privacy: .public) dialog answer: \(answer.action, privacy: .public)")
        type(key)
        if !ClaudeDialog.cancels(answer.action) { confirm(live, sendReturn: live.numbered) }
    }

    /// A numbered option that also takes text waits for Return after its number;
    /// an unnumbered choice already sent Return, so confirm only checks whether it closed.
    private func confirm(_ dialog: ClaudeDialog, sendReturn: Bool) {
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.read()?.options == dialog.options else { return }
            guard sendReturn else {
                return self.journal.record(.status, "Claude did not take the answer; answer it in Terminal")
            }
            self.type("\r")
            self.confirm(dialog, sendReturn: false)
        }
    }

    private func type(_ text: String) {
        if let typeKey { typeKey(text) } else { ScreenRun.type(screen, text) }
    }

    /// The dialog on the screen now, read from a hardcopy of the session's window.
    private func read() -> ClaudeDialog? {
        if let readScreen { return readScreen() }
        return ScreenRun.hardcopy(screen, to: screenFile).flatMap(ClaudeDialog.read(screen:))
    }
}

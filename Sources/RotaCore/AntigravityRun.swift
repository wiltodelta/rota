import Darwin
import Foundation

/// An Antigravity conversation over its NDJSON interface. All mutable state is
/// confined to `queue`; the reader delivers stdout bytes before reporting exit.
/// Messages received mid-turn wait locally for the current result, as agy requires.
final class AntigravityRun: RunControl, @unchecked Sendable {
    private let spec: LaunchSpec
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.antigravity")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [String] = []
    private var stream = AntigravityStream()
    private var outcome: RunOutcome?
    private var stopReason: RunOutcome?
    private var closing = false
    private var questions: AntigravityQuestionArchive?
    private var questionReadFailed = false
    private var sawUnknownStep = false

    private var questionHome: URL {
        URL(fileURLWithPath: spec.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }

    private init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal
        questions = spec.resume.flatMap { AntigravityQuestionArchive(session: $0, home: questionHome,
                                                                    skipExisting: true) }
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> AntigravityRun {
        let run = AntigravityRun(spec: spec, journal: journal)
        try run.launch()
        return run
    }

    static func arguments(resume: String?) -> [String] {
        var arguments = ["--input-format", "stream-json", "--output-format", "stream-json",
                         "--dangerously-skip-permissions"]
        if let resume { arguments += ["--conversation", resume] }
        return arguments
    }

    static func userMessage(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["event": "user", "message": ["content": text]]) + Data([10])
    }

    private func launch() throws {
        let process = ProcessLauncher.loginShellProcess(spec.executable,
            Self.arguments(resume: spec.resume) + spec.modelFlags(effortFlag: "--effort"),
            in: spec.workingDirectory, environment: spec.environment)
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // A single reader orders final output before the exit, including a last
        // JSON object without a newline. No byte crosses queues as an Any value.
        DispatchQueue.global(qos: .utility).async {
            let reader = stdout.fileHandleForReading
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                self.queue.async { self.consume(data) }
            }
            try? reader.close()
            process.waitUntilExit()
            let status = process.terminationStatus
            self.queue.async { self.exited(status) }
        }
        queue.async { self.write(self.spec.prompt) }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(.timedOut) }
        }
    }

    func send(_ message: String) {
        queue.async {
            guard !self.closing, !self.journal.isFinished else { return }
            self.journal.record(.user, message)
            self.pending.append(message)
        }
    }

    func stop() { queue.async { self.end(.cancelled) } }

    private func write(_ message: String) {
        // Each queued turn needs its own result. Preserve a previous failure,
        // but never let the first turn's success hide a missing follow-up result.
        if outcome?.isFailure != true { outcome = nil }
        do { try input?.write(contentsOf: Self.userMessage(message)) } catch {
            journal.record(.error, "Couldn't send the message to Antigravity: \(error.localizedDescription)")
            end(.failed(exitCode: 1))
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard !journal.isFinished else { return }
        for event in stream.events(line) { handle(event) }
    }

    private func handle(_ event: AntigravityStream.Event) {
        switch event {
        case .session(let id):
            if questions?.session != id {
                questions = AntigravityQuestionArchive(session: id, home: questionHome)
            }
            journal.session(id)
        case .unknownStep:
            sawUnknownStep = true
            readQuestions()
        case .configuration(let configuration): journal.configure(configuration)
        case .text(let text): journal.text(text)
        case .item(let kind, let text): journal.record(kind, text)
        case .result(let result):
            readQuestions()
            journal.endText()
            if outcome == nil || result.isFailure { outcome = result }
            if !pending.isEmpty, stopReason == nil {
                write(pending.removeFirst())
            } else {
                closeInput()
            }
        }
    }

    private func readQuestions(final: Bool = false) {
        guard !questionReadFailed else { return }
        do {
            if final, sawUnknownStep,
               questions.map({ !FileManager.default.fileExists(atPath: $0.file.path) }) != false {
                throw CocoaError(.fileNoSuchFile)
            }
            for question in try questions?.read(final: final) ?? [] {
                journal.ask(question, recordText: false) { _ in }
            }
        } catch {
            questionReadFailed = true
            journal.record(.error, "Antigravity's native questions could not be read. "
                + "Question sync is paused; ask the agent to repeat its question in a message.")
        }
    }

    private func closeInput() {
        closing = true
        try? input?.close()
        input = nil
    }

    private func exited(_ status: Int32) {
        if !buffer.isEmpty {
            let tail = buffer
            buffer.removeAll()
            handle(tail)
        }
        closeInput()
        readQuestions(final: true)
        if outcome == nil, stopReason == nil {
            journal.record(.error, "Antigravity exited without a result. The session may be incomplete.")
        }
        let result: RunOutcome = questionReadFailed
            ? .failed(exitCode: 1) : status == 0 ? (outcome ?? .interrupted) : .failed(exitCode: status)
        journal.finish(stopReason ?? result)
    }

    private func end(_ reason: RunOutcome) {
        guard !journal.isFinished, let process, process.isRunning, stopReason == nil else { return }
        stopReason = reason
        closeInput()
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

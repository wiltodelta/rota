import Darwin
import Foundation

/// An Antigravity conversation over its NDJSON interface. All mutable state is
/// confined to `queue`; the reader delivers stdout bytes before reporting exit.
/// Messages received mid-turn wait locally for the current result, as agy requires.
final class AntigravityRun: RunControl, @unchecked Sendable {
    private let spec: LaunchSpec
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.antigravity")
    private var capture: DurableStream?
    private var input: FileHandle?
    private var pending: [String] = []
    private var stream = AntigravityStream()
    private var outcome: RunOutcome?
    private var stopReason: RunOutcome?
    private var closing = false
    private var questions: AntigravityQuestionArchive?
    private var questionReadFailed = false
    private var sawUnknownStep = false
    private var reportedErrors = Set<String>()
    private var writingText = false
    private var textStep: Int?
    private var completedTextStep: Int?

    private var questionHome: URL {
        URL(fileURLWithPath: spec.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }

    init(spec: LaunchSpec, journal: RunJournal) {
        self.spec = spec
        self.journal = journal
        questions = spec.resume.flatMap { AntigravityQuestionArchive(session: $0, home: questionHome,
                                                                    skipExisting: !spec.adopt) }
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> AntigravityRun {
        let run = AntigravityRun(spec: spec, journal: journal)
        if spec.adopt { try run.restore() } else {
            run.queue.async {
                do { try run.launch() } catch {
                    journal.finish(.launchFailed(error.localizedDescription))
                }
            }
        }
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
        var applied = spec
        if let configuration = AntigravityConfiguration.read(spec) {
            // Pin the resolved variant so a later default change cannot alter this launch.
            applied.model = configuration.model
            journal.configure(configuration)
            if let model = configuration.model { journal.line("[session started, \(model)]") }
        }
        let capture = try DurableStream(spec: applied,
            arguments: Self.arguments(resume: applied.resume) + applied.modelFlags(effortFlag: "--effort"))
        self.capture = capture
        input = capture.input
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1)
        queue.async { self.followCapture() }
        queue.async { self.write(self.spec.prompt) }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(.timedOut) }
        }
    }

    private func restore() throws {
        capture = try DurableStream(restoring: spec.log)
        if let session = spec.resume { journal.session(session) }
        queue.async { self.followCapture() }
        if let timeout = spec.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(.timedOut) }
        }
    }

    private func followCapture() {
        capture?.follow(on: queue, line: { data, source in
            self.journal.withSource(source) { self.handle(data) }
        }, ended: { self.exited($0) })
    }

    func send(_ message: String) {
        queue.async {
            guard !self.spec.adopt, !self.closing, !self.journal.isFinished else {
                return self.journal.undelivered(message)
            }
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

    func handle(_ line: Data) {
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
        case .textStarted(let step):
            journal.endText()
            writingText = false
            textStep = step
            readQuestions(reasoningThrough: step)
            writingText = true
        case .textEnded(let step):
            journal.endText()
            writingText = false
            completedTextStep = step
            readQuestions(reasoningThrough: step)
            textStep = nil
        case .text(let text):
            readQuestions()
            let nativeID = textStep.flatMap { step in
                questions.map { "antigravity/\($0.session)/\(step)/text" }
            }
            journal.text(text, nativeID: nativeID)
        case .item(let kind, let text, let step):
            journal.endText()
            writingText = false
            readQuestions(reasoningThrough: step)
            if kind != .error || reportedErrors.insert(text).inserted { journal.record(kind, text) }
        case .result(let result):
            finishTurn(result)
        }
    }

    private func finishTurn(_ result: RunOutcome) {
        journal.endText()
        writingText = false
        completedTextStep = nil
        readQuestions()
        if outcome == nil || result.isFailure { outcome = result }
        if spec.adopt { return }
        if !pending.isEmpty, stopReason == nil {
            write(pending.removeFirst())
        } else {
            closeInput()
        }
    }

    private func readQuestions(final: Bool = false, reasoningThrough step: Int? = nil) {
        guard !questionReadFailed else { return }
        do {
            if final, sawUnknownStep,
               questions.map({ !FileManager.default.fileExists(atPath: $0.file.path) }) != false {
                throw CocoaError(.fileNoSuchFile)
            }
            for question in try questions?.read(final: final) ?? [] {
                journal.ask(question, recordText: false) { _ in }
            }
            if !writingText {
                for (id, text) in questions?.takeErrors() ?? [] where reportedErrors.insert(text).inserted {
                    journal.record(.error, text, nativeID: id)
                }
                for (id, text) in questions?.takeReasoning(through: step ?? completedTextStep) ?? [] {
                    journal.record(.reasoning, text, nativeID: id)
                }
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
        if capture?.alive == true { journal.requireReconciliation() }
        closeInput()
        journal.endText()
        writingText = false
        completedTextStep = nil
        readQuestions(final: true)
        if outcome == nil, stopReason == nil {
            journal.record(.error, "Antigravity exited without a result. The session may be incomplete.")
        }
        let nativeOutcome: RunOutcome
        switch status {
        case 0: nativeOutcome = outcome ?? .interrupted
        case -1: nativeOutcome = .interrupted
        default: nativeOutcome = .failed(exitCode: status)
        }
        journal.finish(stopReason ?? (questionReadFailed ? .failed(exitCode: 1) : nativeOutcome))
    }

    private func end(_ reason: RunOutcome) {
        guard !journal.isFinished, capture?.alive == true, stopReason == nil else { return }
        stopReason = reason
        closeInput()
        capture?.stop(on: queue)
    }
}

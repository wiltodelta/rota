import Foundation
import os

/// The log file of one run plus the once-only finish every runner needs.
final class RunJournal: @unchecked Sendable {
    private let output: FileHandle
    private let events: RunEvents
    private let lock = NSLock()
    private let startedAt = Date()
    private var finished = false
    private var closed = false
    private var pendingText = ""
    private var pendingID: Int?
    private var pendingKind = TranscriptItem.Kind.agent
    private var pendingNativeID: String?
    private var nativeItems: [String: String]
    private var transcript: TranscriptJournal?
    private let images: SessionImageStore?
    private var reportedConfiguration = SessionConfiguration()
    private var sourceIDs: Set<String>
    private let sourceKey = "rota-journal-" + UUID().uuidString

    private final class SourceFrame {
        let id: String
        var index = 0
        init(_ id: String) { self.id = id }
    }

    init(output: FileHandle, events: RunEvents, transcript: TranscriptJournal? = nil,
         images: SessionImageStore? = nil) {
        self.output = output
        self.events = events
        self.transcript = transcript
        self.images = images
        sourceIDs = transcript?.sourceIDs ?? []
        nativeItems = transcript?.nativeItems ?? [:]
        if let item = transcript?.unfinished {
            pendingID = item.id
            pendingText = item.text
            pendingKind = item.kind
            pendingNativeID = item.nativeID
            if let id = item.nativeID { nativeItems[id] = nil }
        }
    }

    /// The thread-local frame cannot leak into an asynchronous human answer callback.
    func withSource(_ source: String, _ body: () -> Void) {
        let old = Thread.current.threadDictionary[sourceKey]
        Thread.current.threadDictionary[sourceKey] = SourceFrame(source)
        defer { Thread.current.threadDictionary[sourceKey] = old }
        body()
    }

    private func nextSource() -> String? {
        guard let frame = Thread.current.threadDictionary[sourceKey] as? SourceFrame else { return nil }
        defer { frame.index += 1 }
        return frame.id + "/\(frame.index)"
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// Diagnostic lines are Rota's own metadata, never provider message content.
    func line(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let source = nextSource()
        if let source, !sourceIDs.insert(source).inserted { return }
        flushText()
        write(text)
        if let (kind, body) = Transcript.classify(text, shell: false) {
            appendItem(kind, body, sourceID: source)
        } else {
            persist(TranscriptRecord(type: "checkpoint", required: false,
                                     logSize: output.offsetInFile, sourceID: source))
        }
    }

    /// The adapter chooses the kind before content reaches either storage format.
    func record(_ kind: TranscriptItem.Kind, _ text: String, nativeID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if let nativeID, nativeItems[nativeID] != nil { return }
        let source = nextSource()
        if let source, !sourceIDs.insert(source).inserted { return }
        flushText()
        var body = text
        var imageWarning: String?
        if kind == .output {
            do { body = try images?.preserveOutput(text, itemID: transcript?.nextID) ?? text } catch {
                imageWarning = "Couldn't preserve a tool image: " + error.localizedDescription
            }
        }
        let item = TranscriptItem(id: 0, kind: kind, text: body).presented
        if item.kind == .agent { captureImages(item.text, itemID: transcript?.nextID) }
        write(Self.readable(item.kind, item.text))
        appendItem(item.kind, item.text, sourceID: source, nativeID: nativeID)
        if let nativeID { nativeItems[nativeID] = text }
        if let imageWarning {
            write(Self.readable(.status, imageWarning))
            appendItem(.status, imageWarning)
        }
    }

    /// Partial text is visible immediately; the readable log gets one completed message.
    func text(_ chunk: String, kind: TranscriptItem.Kind = .agent, nativeID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !chunk.isEmpty else { return }
        let source = nextSource()
        if let source, !sourceIDs.insert(source).inserted { return }
        if pendingKind != kind || pendingNativeID != nativeID { flushText() }
        pendingKind = kind
        pendingNativeID = nativeID
        pendingText += chunk
        if let pendingID {
            persist(TranscriptRecord(type: "append", id: pendingID, text: chunk,
                                     logSize: output.offsetInFile, sourceID: source))
        } else if let transcript {
            let id = transcript.allocateID()
            pendingID = id
            persist(TranscriptRecord(type: "item", id: id, kind: kind.rawValue, text: chunk,
                                     complete: false, logSize: output.offsetInFile,
                                     sourceID: source, nativeID: nativeID))
        }
    }

    func endText() {
        lock.lock()
        defer { lock.unlock() }
        flushText()
    }

    /// History can contain the full message whose prefix was streamed before the host stopped.
    func reconcileText(_ text: String, kind: TranscriptItem.Kind, nativeID: String) {
        let prior = lock.withLock { pendingNativeID == nativeID ? pendingText : nativeItems[nativeID] }
        if let prior {
            if text == prior { return endText() }
            if text.hasPrefix(prior) {
                self.text(String(text.dropFirst(prior.count)), kind: kind, nativeID: nativeID)
                return endText()
            }
            return record(.status, "The provider revised a previously recorded message; see its native history.")
        }
        record(kind, text, nativeID: nativeID)
    }

    static func readable(_ kind: TranscriptItem.Kind, _ text: String) -> String {
        switch kind {
        case .user: return Transcript.userLines(text)
        case .tool: return "-> " + text
        case .status: return "[rota: " + text + "]"
        case .error: return "[error] " + text
        case .plan:
            return ([PlanStep.prefix + PlanStep.header] + text.components(separatedBy: "\n")
                .map { PlanStep.prefix + $0 }).joined(separator: "\n")
        case .agent: return text
        case .reasoning, .output:
            let text = kind == .output ? ToolOutput.decode(text)?.readable ?? text : text
            return text.components(separatedBy: "\n").map { "[\(kind.rawValue)] " + $0 }.joined(separator: "\n")
        }
    }

    /// Hands back a message that arrived as the session ended; the scheduler continues the session with it.
    func undelivered(_ message: String) {
        DispatchQueue.main.async { self.events.undelivered(message) }
    }

    func terminalInput() {
        DispatchQueue.main.async { self.events.terminalInput() }
    }

    func terminalState(_ state: TerminalState) {
        DispatchQueue.main.async { self.events.terminalState(state) }
    }

    func session(_ id: String) {
        DispatchQueue.main.async { self.events.session(id) }
    }

    func ask(_ question: AgentQuestion, recordText: Bool = true,
             reply: @escaping @Sendable (QuestionAnswer) -> Void) {
        guard !isFinished else { return reply(.init(action: "cancel")) }
        if recordText {
            let body = ([question.title, question.detail] + question.fields.flatMap { field in
                [field.title] + field.options.map { $0.label + ($0.detail.isEmpty ? "" : ": " + $0.detail) }
            }).filter { !$0.isEmpty }.joined(separator: "\n")
            record(.agent, body)
        }
        DispatchQueue.main.async {
            self.events.question(question) { answer in
                let visible = question.fields.map { field in
                    field.title + ": " + (field.kind == .secret ? "[private answer]"
                        : (answer.values[field.id] ?? []).joined(separator: ", "))
                }
                self.record(.user, ([answer.action] + visible).joined(separator: "\n"))
                reply(answer)
            }
        }
    }

    func resolveQuestion(_ id: String) {
        DispatchQueue.main.async { self.events.questionResolved(id) }
    }

    func configure(_ configuration: SessionConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        var next = reportedConfiguration
        if let model = configuration.model {
            if model != next.model { next.modelTitle = nil }
            next.model = model
        }
        if let title = configuration.modelTitle { next.modelTitle = title }
        if let effort = configuration.effort { next.effort = effort }
        guard next != reportedConfiguration else { return }
        reportedConfiguration = next
        DispatchQueue.main.async { [next] in self.events.configuration(next) }
    }

    func provenance(cli: String? = nil, server: String? = nil) {
        DispatchQueue.main.async { self.events.provenance(cli, server) }
    }

    func requireReconciliation() {
        DispatchQueue.main.async { self.events.reconciliationRequired() }
    }

    /// Reports the outcome once and closes the log.
    func finish(_ outcome: RunOutcome) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        flushText()
        let note = "\(outcome.title) after \(Int(Date().timeIntervalSince(startedAt))) s"
        write(Self.readable(.status, note))
        appendItem(.status, Transcript.readableDurations(note))
        closed = true
        try? output.close()
        lock.unlock()
        DispatchQueue.main.async { self.events.finished(outcome) }
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        let itemID = pendingID
        write(Self.readable(pendingKind, text.trimmingCharacters(in: .newlines)))
        if let itemID {
            persist(TranscriptRecord(type: "complete", id: itemID, logSize: output.offsetInFile))
        }
        pendingID = nil
        if let id = pendingNativeID { nativeItems[id] = text }
        pendingNativeID = nil
        pendingText = ""
        // Archiving may add a warning. Complete the streamed entry first so
        // every page remains a sequence of independently replayable messages.
        if pendingKind == .agent { captureImages(text, itemID: itemID) }
    }

    private func captureImages(_ text: String, itemID: Int?) {
        do {
            try images?.capture(MarkdownImageReference.references(in: MarkdownBlock.parse(text)), itemID: itemID)
        } catch {
            // The original URL still renders; make the missing durable copy explicit.
            write(Self.readable(.status, "Couldn't preserve an image: " + error.localizedDescription))
            appendItem(.status, "Couldn't preserve an image: " + error.localizedDescription)
        }
    }

    private func appendItem(_ kind: TranscriptItem.Kind, _ text: String,
                            sourceID: String? = nil, nativeID: String? = nil) {
        guard let transcript else { return }
        persist(TranscriptRecord(type: "item", id: transcript.allocateID(), kind: kind.rawValue,
                                 text: text, logSize: output.offsetInFile, sourceID: sourceID, nativeID: nativeID))
    }

    private func persist(_ record: TranscriptRecord) {
        do { try transcript?.append(record) } catch {
            // The log size will no longer match the last accepted record. Readers
            // show an explicit fallback rather than presenting a stale journal as complete.
            transcript = nil
            write("[error] Couldn't save chat history. The readable log is still available.")
            ProcessLauncher.log.error("Couldn't save normalized chat history")
        }
    }

    private func write(_ text: String) {
        guard !closed else { return }
        // Append: a shell run's tee writes the same file.
        output.seekToEndOfFile()
        output.write(Data((text + "\n").utf8))
    }
}

/// Single-quotes `text` for zsh.
public func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

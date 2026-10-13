import Foundation
import os

/// Serializes the readable log and normalized events under one lock; callbacks use the main queue.
final class RunJournal: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "journal")
    private let output: FileHandle
    private let eventOutput: FileHandle
    private let events: RunEvents
    private let lock = NSLock()
    private let startedAt = Date()
    let turnID = UUID().uuidString
    let initialMessageID: String
    private var finished = false
    private var closed = false
    private var eventWriteFailed = false
    private var pendingText = ""
    private struct UserMessage {
        var id: String
        var text: String
        var state: MessageDelivery = .pending
    }
    private var users: [UserMessage] = []

    init(output: FileHandle, events: RunEvents, spec: LaunchSpec, legacy: String?) throws {
        self.output = output
        self.events = events
        initialMessageID = spec.messageID
        let file = SessionEventReader.file(for: spec.log)
        if spec.resume == nil || !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        eventOutput = try FileHandle(forWritingTo: file)
        try eventOutput.seekToEnd()
        if let legacy, !legacy.isEmpty { emit(.legacy(text: legacy, shell: spec.mode == .screen)) }
        emit(.started(SessionMetadata(model: spec.model, effort: spec.effort)))
        user(spec.chatMessage, id: spec.messageID, echo: spec.mode == .claudeStream
             ? spec.chatMessage.claudeText : spec.chatMessage.fileReferenceText)
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func event(_ payload: SessionEvent.Payload) {
        lock.lock()
        defer { lock.unlock() }
        emit(payload)
        if case .metadata(let value) = payload {
            DispatchQueue.main.async { self.events.metadata(value) }
        }
    }

    func metadata(model: String?, effort: String? = nil) {
        let value = SessionMetadata(model: model, effort: effort)
        event(.metadata(value))
    }

    func user(_ message: ChatMessage, id: String, echo: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        users.append(UserMessage(id: id, text: echo ?? message.fileReferenceText))
        emit(.user(id: id, text: message.text, delivery: .pending))
        if !message.attachments.isEmpty { emit(.attachments(id: id, files: message.attachments)) }
    }

    func delivery(_ id: String, _ state: MessageDelivery) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = users.firstIndex(where: { $0.id == id }) else { return }
        users[index].state = state
        emit(.delivery(id: id, state: state))
    }

    /// Provider transcript echoes confirm the oldest unconfirmed matching message, not its local log.
    func confirmUser(_ text: String, queued: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = users.firstIndex(where: {
            $0.text == text && ($0.state == .pending || $0.state == .written)
        }) else { return }
        let state: MessageDelivery = queued ? .queued : .accepted
        users[index].state = state
        emit(.delivery(id: users[index].id, state: state))
    }

    func line(_ text: String, structured: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        flushText()
        write(text)
        if structured {
            let error = text.hasPrefix("[error] ")
            emit(.note(text: error ? String(text.dropFirst(8)) : text, error: error))
        }
    }

    /// Log buffering does not delay the corresponding structured delta.
    func text(_ chunk: String, id: String = "assistant", phase: MessagePhase? = nil) {
        lock.lock()
        defer { lock.unlock() }
        pendingText += chunk
        emit(.delta(id: id, text: chunk, phase: phase))
    }

    func endText() {
        lock.lock()
        defer { lock.unlock() }
        flushText()
    }

    func requests(_ requests: [SessionRequest]) {
        DispatchQueue.main.async { self.events.requests(requests) }
    }

    func session(_ id: String) {
        DispatchQueue.main.async { self.events.session(id) }
    }

    func finish(_ outcome: RunOutcome) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        flushText()
        for index in users.indices where users[index].state == .pending {
            let state = MessageDelivery.unconfirmed("The session ended before delivery was confirmed.")
            users[index].state = state
            emit(.delivery(id: users[index].id, state: state))
        }
        emit(.finished(outcome))
        write("[rota: \(outcome.title) after \(Int(Date().timeIntervalSince(startedAt))) s]")
        closed = true
        try? output.close()
        try? eventOutput.close()
        lock.unlock()
        DispatchQueue.main.async { self.events.finished(outcome) }
    }

    private func emit(_ payload: SessionEvent.Payload) {
        guard !closed else { return }
        do {
            let data = try JSONEncoder().encode(SessionEvent(turnID: turnID, payload: payload))
            try eventOutput.write(contentsOf: data + Data("\n".utf8))
        } catch {
            // No user content or serialized request is included in application logs.
            Self.log.error("Could not save a session event: \(error.localizedDescription, privacy: .public)")
            if !eventWriteFailed {
                eventWriteFailed = true
                let reason = error.localizedDescription
                DispatchQueue.main.async { self.events.eventError(reason) }
            }
        }
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        write(pendingText.trimmingCharacters(in: .newlines))
        pendingText = ""
    }

    private func write(_ text: String) {
        guard !closed else { return }
        output.seekToEndOfFile()
        output.write(Data((text + "\n").utf8))
    }
}

/// Single-quotes `text` for zsh.
public func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

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

    init(output: FileHandle, events: RunEvents) {
        self.output = output
        self.events = events
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func line(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        flushText()
        write(text)
    }

    /// Streamed message text, joined until the next line or the end.
    func text(_ chunk: String) {
        lock.lock()
        pendingText += chunk
        lock.unlock()
    }

    /// Ends the streamed message, so the next turn's text starts on its own line.
    func endText() {
        lock.lock()
        defer { lock.unlock() }
        flushText()
    }

    func session(_ id: String) {
        DispatchQueue.main.async { self.events.session(id) }
    }

    /// Reports the outcome once and closes the log.
    func finish(_ outcome: RunOutcome) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        flushText()
        write("[rota: \(outcome.title) after \(Int(Date().timeIntervalSince(startedAt))) s]")
        closed = true
        try? output.close()
        lock.unlock()
        DispatchQueue.main.async { self.events.finished(outcome) }
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        write(pendingText.trimmingCharacters(in: .newlines))
        pendingText = ""
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

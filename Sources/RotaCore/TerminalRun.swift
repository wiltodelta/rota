import Foundation
import Darwin

/// Owns the resumed CLI's terminal, but follows the provider's structured history.
/// Closing a terminal window detaches; exiting the CLI or Stop ends the run.
final class TerminalRun: RunControl, @unchecked Sendable {
    private let journal: RunJournal
    private let name: String
    private let script: URL
    private let exitFile: URL
    private let childFile: URL
    private var child: Child?
    private var transcript: NativeTranscript
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.terminal")
    private var stopReason: RunOutcome?
    private var readingTranscript = true

    private init(journal: RunJournal, name: String, script: URL, exitFile: URL, transcript: NativeTranscript) {
        self.journal = journal
        self.name = name
        self.script = script
        self.exitFile = exitFile
        childFile = script.appendingPathExtension("pid")
        self.transcript = transcript
    }

    var attachCommand: [String]? { [ScreenRun.screen, "-x", name] }

    static func start(_ spec: LaunchSpec, harness: Harness, journal: RunJournal) throws -> TerminalRun {
        guard let source = spec.terminalTranscript else { throw CocoaError(.fileNoSuchFile) }
        let transcript = try NativeTranscript(url: source, harness: harness)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/screen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "rota-terminal-" + UUID().uuidString.lowercased()
        let script = folder.appendingPathComponent(name + ".zsh")
        let exitFile = folder.appendingPathComponent(name + ".exit")
        let run = TerminalRun(journal: journal, name: name, script: script, exitFile: exitFile,
                              transcript: transcript)
        do {
            try scriptText(spec, exitFile: exitFile, childFile: run.childFile)
                .write(to: script, atomically: true, encoding: .utf8)
            let process = ProcessLauncher.loginShellProcess(
                ScreenRun.screen, ["-dmS", name, "/bin/zsh", "-l", script.path],
                in: spec.workingDirectory, environment: spec.environment)
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LaunchError.screenFailed(process.terminationStatus) }
        } catch {
            run.cleanUp()
            throw error
        }
        journal.record(.status, "Continued in Terminal")
        run.queue.async { run.poll() }
        return run
    }

    /// The wrapper writes its PID and parent before exec, preserving the original
    /// PTY descriptors. Rota captures its kernel birth time before taking ownership.
    static func scriptText(_ spec: LaunchSpec, exitFile: URL, childFile: URL) -> String {
        let wrapper = "print -r -- \"$$ $PPID\" > \"$0\"; exec \"$@\""
        let command = (["/bin/zsh", "-c", wrapper, childFile.path, spec.executable] + spec.arguments)
            .map(shellQuote).joined(separator: " ")
        return """
        cd \(shellQuote(spec.workingDirectory)) || { print -r -- 1 > \(shellQuote(exitFile.path)); exit 1 }
        \(command)
        print -r -- $? > \(shellQuote(exitFile.path))
        """
    }

    func stop() { queue.async { self.end(as: .cancelled) } }

    private func poll() {
        guard !journal.isFinished else { return }
        captureChild()
        readTranscript()
        if let status = exitStatus {
            return finish(stopReason ?? (status == 0 ? .succeeded : .failed(exitCode: status)))
        }
        if !ClaudeInteractiveRun.alive(name) {
            if child?.exists == true {
                end(as: .interrupted)
                queue.asyncAfter(deadline: .now() + 1) { self.poll() }
                return
            }
            return finish(stopReason ?? exitStatus.map { $0 == 0 ? .succeeded : .failed(exitCode: $0) } ?? .interrupted)
        }
        queue.asyncAfter(deadline: .now() + 1) { self.poll() }
    }

    private func readTranscript() {
        guard readingTranscript else { return }
        do {
            for event in try transcript.read() {
                switch event {
                case .item(let kind, let text):
                    journal.record(kind, text)
                    if kind == .user { journal.terminalInput() }
                case .chunk(let text): journal.text(text)
                case .configuration(let configuration): journal.configure(configuration)
                case .state(let state):
                    if state == .waiting { journal.endText() }
                    journal.terminalState(state)
                    if state == .waiting, stopReason != nil { quitScreen() }
                }
            }
        } catch {
            readingTranscript = false
            journal.record(.error, "Terminal history could not be read. Sync is paused; continue in Terminal.")
        }
    }

    private var exitStatus: Int32? {
        guard let text = try? String(contentsOf: exitFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func end(as outcome: RunOutcome) {
        guard stopReason == nil else { return }
        stopReason = outcome
        // Let the native TUI cancel its turn before disconnecting from its backend.
        _ = ProcessLauncher.capture(ScreenRun.screen, ["-S", name, "-X", "stuff", "\u{03}"],
                                    in: NSTemporaryDirectory(), loginShell: false)
        queue.asyncAfter(deadline: .now() + 3) { self.quitScreen() }
    }

    private func quitScreen() {
        guard !journal.isFinished else { return }
        captureChild()
        child?.signal(SIGTERM)
        queue.asyncAfter(deadline: .now() + 2) { self.child?.signal(SIGKILL) }
        _ = ProcessLauncher.capture(ScreenRun.screen, ["-S", name, "-X", "quit"],
                                    in: NSTemporaryDirectory(), loginShell: false)
    }

    private func captureChild() {
        guard child == nil, let text = try? String(contentsOf: childFile, encoding: .utf8) else { return }
        let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        guard numbers.count == 2, numbers[0] > 1, let identity = Child(pid: numbers[0]),
              identity.parent == numbers[1] else { return }
        child = identity
    }

    private struct Child {
        let pid: Int32
        let parent: UInt32
        let seconds: UInt64
        let microseconds: UInt64

        init?(pid: Int32) {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0
            else { return nil }
            self.pid = pid
            parent = info.pbi_ppid
            seconds = info.pbi_start_tvsec
            microseconds = info.pbi_start_tvusec
        }

        var exists: Bool {
            guard let current = Child(pid: pid) else { return false }
            return current.seconds == seconds && current.microseconds == microseconds
        }

        func signal(_ signal: Int32) {
            if exists { kill(pid, signal) }
        }
    }

    private func finish(_ outcome: RunOutcome) {
        // Read again after observing exit: the final message may follow the poll's first read.
        readTranscript()
        journal.finish(outcome)
        cleanUp()
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: script)
        try? FileManager.default.removeItem(at: exitFile)
        try? FileManager.default.removeItem(at: childFile)
    }
}

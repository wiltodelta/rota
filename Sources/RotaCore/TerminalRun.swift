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
    private var child: OwnedProcess?
    private var transcript: NativeTranscript
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.terminal")
    private var stopReason: RunOutcome?
    private var stopping: [OwnedProcess] = []
    private var readingTranscript = true
    private let log: URL
    private var lease: RunLease?

    private init(journal: RunJournal, name: String, script: URL, exitFile: URL,
                 transcript: NativeTranscript, log: URL) {
        self.journal = journal
        self.name = name
        self.script = script
        self.exitFile = exitFile
        childFile = script.appendingPathExtension("pid")
        self.transcript = transcript
        self.log = log
    }

    var attachCommand: [String]? { [ScreenRun.screen, "-x", name] }

    static func start(_ spec: LaunchSpec, harness: Harness, journal: RunJournal) throws -> TerminalRun {
        if spec.adopt { return try restore(spec, harness: harness, journal: journal) }
        guard let source = spec.terminalTranscript else { throw CocoaError(.fileNoSuchFile) }
        let transcript = try NativeTranscript(url: source, harness: harness)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/screen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "rota-terminal-" + UUID().uuidString.lowercased()
        let script = folder.appendingPathComponent(name + ".zsh")
        let exitFile = folder.appendingPathComponent(name + ".exit")
        let run = TerminalRun(journal: journal, name: name, script: script, exitFile: exitFile,
                              transcript: transcript, log: spec.log)
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
        run.lease = RunLease(process: ScreenRun.pid(name).flatMap(OwnedProcess.init),
                             id: UUID().uuidString, screenName: name, nativeOffset: transcript.checkpoint)
        try run.lease?.write(spec.log)
        run.queue.async { run.poll() }
        return run
    }

    private static func restore(_ spec: LaunchSpec, harness: Harness, journal: RunJournal) throws -> TerminalRun {
        guard let lease = RunLease.read(spec.log), let name = lease.screenName,
              name.hasPrefix("rota-terminal-"), !name.contains("/"), !name.contains(".."),
              let offset = lease.nativeOffset, let session = spec.resume,
              let source = spec.terminalTranscript ?? NativeTranscript.locate(harness, session: session) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/screen")
        let run = TerminalRun(journal: journal, name: name, script: folder.appendingPathComponent(name + ".zsh"),
            exitFile: folder.appendingPathComponent(name + ".exit"),
            transcript: try NativeTranscript(url: source, harness: harness, offset: offset), log: spec.log)
        run.lease = lease
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
        if stopReason != nil, stopping.contains(where: { $0.exists }) {
            queue.asyncAfter(deadline: .now() + 0.1) { self.poll() }
            return
        }
        if let status = exitStatus {
            return finish(stopReason ?? (status == 0 ? .succeeded : .failed(exitCode: status)))
        }
        if !ScreenRun.alive(name) {
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
            let journal = self.journal
            _ = try transcript.read { events, source in
                journal.withSource(source) {
                    for event in events { self.handle(event) }
                }
            }
            if lease?.nativeOffset != transcript.checkpoint {
                lease?.nativeOffset = transcript.checkpoint
                try lease?.write(log)
            }
        } catch {
            readingTranscript = false
            journal.record(.error, "Terminal history could not be read. Sync is paused; continue in Terminal.")
        }
    }

    private func handle(_ event: NativeTranscript.Event) {
        switch event {
        case .item(let kind, let text):
            journal.record(kind, text)
            if kind == .user { journal.terminalInput() }
        case .chunk(let text, let kind): journal.text(text, kind: kind)
        case .configuration(let configuration): journal.configure(configuration)
        case .state(let state):
            if state == .waiting { journal.endText() }
            journal.terminalState(state)
            if state == .waiting, stopReason != nil { quitScreen() }
        }
    }

    private var exitStatus: Int32? {
        guard let text = try? String(contentsOf: exitFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func end(as outcome: RunOutcome) {
        guard stopReason == nil else { return }
        stopReason = outcome
        captureChild()
        if let child { stopping = child.descendants() + [child] }
        // Let the native TUI cancel its turn before disconnecting from its backend.
        ScreenRun.command(name, ["-X", "stuff", "\u{03}"])
        queue.asyncAfter(deadline: .now() + 3) { self.quitScreen() }
    }

    private func quitScreen() {
        guard !journal.isFinished else { return }
        captureChild()
        if stopping.isEmpty, let child { stopping = child.descendants() + [child] }
        let owned = stopping
        for process in owned { process.signal(SIGTERM) }
        queue.asyncAfter(deadline: .now() + 2) { for process in owned { process.signal(SIGKILL) } }
        ScreenRun.quit(name)
    }

    private func captureChild() {
        guard child == nil, let text = try? String(contentsOf: childFile, encoding: .utf8) else { return }
        let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        guard numbers.count == 2, numbers[0] > 1, let identity = OwnedProcess(pid: numbers[0]),
              identity.parent == numbers[1] else { return }
        child = identity
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

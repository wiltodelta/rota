import Foundation

/// A shell routine run inside a detached `screen` session, so the user can
/// attach (`screen -r`) and type into it while it runs. A script writes the
/// command's exit status to a file, which the run polls for.
final class ScreenRun: RunControl, @unchecked Sendable {
    static let screen = "/usr/bin/screen"

    static func alive(_ name: String) -> Bool {
        let (_, output) = ProcessLauncher.capture(screen, ["-ls", name], in: NSTemporaryDirectory(), loginShell: false)
        return output.contains("." + name)
    }

    private let journal: RunJournal
    private let name: String
    private let exitFile: URL
    private let script: URL
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.screen")
    private var stopReason: RunOutcome?

    private init(journal: RunJournal, name: String, exitFile: URL, script: URL) {
        self.journal = journal
        self.name = name
        self.exitFile = exitFile
        self.script = script
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> ScreenRun {
        let name = "rota-" + UUID().uuidString.prefix(8).lowercased()
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/screen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("\(name).zsh")
        let exitFile = folder.appendingPathComponent("\(name).exit")
        try scriptText(command: spec.prompt, directory: spec.workingDirectory, log: spec.log, exitFile: exitFile)
            .write(to: script, atomically: true, encoding: .utf8)
        // The command's output reaches the log through tee; keep the journal's
        // handle out of the way until the end.
        let process = ProcessLauncher.loginShellProcess(screen, ["-dmS", name, "/bin/zsh", "-l", script.path],
                                                        in: spec.workingDirectory, environment: spec.environment)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LaunchError.screenFailed(process.terminationStatus)
        }
        let run = ScreenRun(journal: journal, name: name, exitFile: exitFile, script: script)
        journal.session(name)
        if let timeout = spec.timeout {
            run.queue.asyncAfter(deadline: .now() + timeout) { [weak run] in run?.end(as: .timedOut) }
        }
        run.poll()
        return run
    }

    static func scriptText(command: String, directory: String, log: URL, exitFile: URL) -> String {
        """
        cd \(shellQuote(directory)) || { print -r -- 1 > \(shellQuote(exitFile.path)); exit 1 }
        { \(command)
        } 2>&1 | tee -a \(shellQuote(log.path))
        print -r -- ${pipestatus[1]} > \(shellQuote(exitFile.path))
        """
    }

    func stop() {
        queue.async { self.end(as: .cancelled) }
    }

    private func poll() {
        var status = exitStatus
        if status == nil, !isAlive() {
            // The script writes the exit file before screen ends, so a command that
            // ended after the first read shows up now; without it, it was killed.
            status = exitStatus
            if status == nil { return finish(stopReason ?? .interrupted) }
        }
        if let status {
            return finish(stopReason ?? (status == 0 ? .succeeded : .failed(exitCode: status)))
        }
        // Strong on purpose: the run keeps itself alive until the command ends.
        queue.asyncAfter(deadline: .now() + 2) { self.poll() }
    }

    private var exitStatus: Int32? {
        guard let text = try? String(contentsOf: exitFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isAlive() -> Bool {
        let (_, output) = ProcessLauncher.capture(Self.screen, ["-ls", name], in: NSTemporaryDirectory())
        return output.contains(".\(name)")
    }

    private func end(as reason: RunOutcome) {
        guard !journal.isFinished, stopReason == nil else { return }
        stopReason = reason
        _ = ProcessLauncher.capture(Self.screen, ["-S", name, "-X", "quit"], in: NSTemporaryDirectory())
    }

    private func finish(_ outcome: RunOutcome) {
        journal.finish(outcome)
        try? FileManager.default.removeItem(at: exitFile)
        try? FileManager.default.removeItem(at: script)
    }
}

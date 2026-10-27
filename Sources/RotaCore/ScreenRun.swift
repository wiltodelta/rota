import Darwin
import Foundation

/// A shell routine run inside a detached `screen` session, so the user can
/// attach (`screen -r`) and type into it while it runs. A script writes the
/// command's exit status to a file, which the run polls for.
final class ScreenRun: RunControl, @unchecked Sendable {
    static let screen = "/usr/bin/screen"
    /// `screen -X` hung while Claude inside retried an unreachable API (2026-10-26); on a run's
    /// queue that also held Stop and the time limit, so every command to a session is bounded.
    static let commandTimeout: TimeInterval = 5

    /// Sends `screen -S name <arguments>` within the deadline; returns the exit status.
    @discardableResult
    static func command(_ name: String, _ arguments: [String]) -> Int32 {
        ProcessLauncher.capture(screen, ["-S", name] + arguments, in: NSTemporaryDirectory(),
                                timeout: commandTimeout, loginShell: false).0
    }

    /// The pid of the session named exactly `name`, as `screen -ls` lists it.
    static func pid(_ name: String) -> pid_t? {
        pid(name, in: ProcessLauncher.capture(screen, ["-ls", name], in: NSTemporaryDirectory(),
                                              loginShell: false).1)
    }

    static func pid(_ name: String, in list: String) -> pid_t? {
        list.split(whereSeparator: \.isWhitespace).lazy.compactMap { field -> pid_t? in
            let parts = field.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, parts[1] == name else { return nil }
            return pid_t(parts[0])
        }.first
    }

    static func alive(_ name: String) -> Bool { pid(name) != nil }

    /// Types `text` into the first window of session `name`, as keys.
    static func type(_ name: String, _ text: String) { command(name, ["-p", "0", "-X", "stuff", text]) }

    /// Quits session `name`; a wedged screen that ignores its own commands is ended by its pid.
    static func quit(_ name: String) {
        guard command(name, ["-X", "quit"]) != 0, let pid = pid(name) else { return }
        kill(pid, SIGTERM)
    }

    private let journal: RunJournal
    private let name: String
    private let exitFile: URL
    private let script: URL
    private let childFile: URL
    private var children: [OwnedProcess] = []
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.screen")
    private var stopReason: RunOutcome?

    private init(journal: RunJournal, name: String, exitFile: URL, script: URL) {
        self.journal = journal
        self.name = name
        self.exitFile = exitFile
        self.script = script
        childFile = exitFile.appendingPathExtension("pid")
    }

    static func start(_ spec: LaunchSpec, journal: RunJournal) throws -> ScreenRun {
        let name = spec.adopt ? (spec.resume ?? "") : "rota-" + UUID().uuidString.prefix(8).lowercased()
        guard name.hasPrefix("rota-"), !name.contains("/"), !name.contains("..") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/screen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("\(name).zsh")
        let exitFile = folder.appendingPathComponent("\(name).exit")
        let run = ScreenRun(journal: journal, name: name, exitFile: exitFile, script: script)
        if spec.adopt {
            journal.session(name)
            journal.record(.status, "Following the shell command that kept running while Rota was closed")
            run.queue.async { run.poll() }
            if let timeout = spec.timeout {
                run.queue.asyncAfter(deadline: .now() + timeout) { [weak run] in run?.end(as: .timedOut) }
            }
            return run
        }
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
        { zmodload zsh/system
        print -r -- "$sysparams[pid] $sysparams[ppid]" > \(shellQuote(exitFile.appendingPathExtension("pid").path))
        \(command)
        } 2>&1 | tee -a \(shellQuote(log.path))
        print -r -- ${pipestatus[1]} > \(shellQuote(exitFile.path))
        """
    }

    func stop() {
        queue.async { self.end(as: .cancelled) }
    }

    private func poll() {
        guard !journal.isFinished else { return }
        captureChildren()
        if stopReason != nil, children.contains(where: { $0.exists }) {
            queue.asyncAfter(deadline: .now() + 0.1) { self.poll() }
            return
        }
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

    private func isAlive() -> Bool { Self.alive(name) }

    private func end(as reason: RunOutcome) {
        guard !journal.isFinished, stopReason == nil else { return }
        stopReason = reason
        captureChildren()
        if let pid = Self.pid(name), let screen = OwnedProcess(pid: pid) {
            children = screen.descendants() + children
        }
        for child in children { child.signal(SIGTERM) }
        let owned = children
        queue.asyncAfter(deadline: .now() + 2) { for child in owned { child.signal(SIGKILL) } }
        Self.quit(name)
    }

    private func captureChildren() {
        guard let text = try? String(contentsOf: childFile, encoding: .utf8) else { return }
        let ids = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        guard ids.count == 2, let child = OwnedProcess(pid: ids[0]), child.parent == UInt32(ids[1]) else { return }
        children = child.descendants() + [child]
    }

    private func finish(_ outcome: RunOutcome) {
        journal.finish(outcome)
        try? FileManager.default.removeItem(at: exitFile)
        try? FileManager.default.removeItem(at: script)
        try? FileManager.default.removeItem(at: childFile)
    }
}

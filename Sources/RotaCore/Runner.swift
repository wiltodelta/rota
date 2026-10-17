import Foundation
import os

/// Everything needed to start one run.
public struct LaunchSpec: Equatable, Sendable {
    public var executable: String
    /// The prompt, or for a shell routine the command.
    public var prompt: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    public var mode: LaunchMode
    /// nil: no limit.
    public var timeout: TimeInterval?
    public var log: URL
    /// The session to continue with `prompt` as the next message, instead of starting one.
    public var resume: String?
    /// The model and reasoning effort; nil leaves the CLI's default. Each runner
    /// passes them its own way: flags for Claude and Grok, protocol fields for Codex.
    public var model: String?
    public var effort: String?
    /// A note the log opens with, such as why a Claude run is not interactive.
    public var notice: String?

    public init(executable: String, prompt: String, arguments: [String], workingDirectory: String,
                environment: [String: String], mode: LaunchMode, timeout: TimeInterval?, log: URL,
                resume: String? = nil, model: String? = nil, effort: String? = nil) {
        self.executable = executable
        self.prompt = prompt
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.mode = mode
        self.timeout = timeout
        self.log = log
        self.resume = resume
        self.model = model
        self.effort = effort
    }

    /// `--model` and the CLI's effort flag, for the values that are set.
    func modelFlags(effortFlag: String) -> [String] {
        [("--model", model), (effortFlag, effort)].flatMap { flag, value in value.map { [flag, $0] } ?? [] }
    }
}

public protocol RunControl: AnyObject {
    func stop()
    /// Delivers a message from the user into the running session, where the harness allows it.
    func send(_ message: String)
    /// The command that shows the running session in a terminal, when it runs in one.
    var attachCommand: [String]? { get }
}

public extension RunControl {
    func send(_ message: String) {}
    var attachCommand: [String]? { nil }
}

/// Callbacks of one run, all delivered on the main queue.
public struct RunEvents {
    /// The harness session the run lives in, once known; it is what "Open chat" opens.
    public var session: (String) -> Void
    /// Fires once, when the run's work is over.
    public var finished: (RunOutcome) -> Void

    public init(session: @escaping (String) -> Void, finished: @escaping (RunOutcome) -> Void) {
        self.session = session
        self.finished = finished
    }
}

/// Starts runs. The scheduler talks to this seam so tests never spawn an agent.
public protocol RoutineLaunching {
    /// Starts the run, or throws when it cannot.
    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl
}

public enum LaunchError: Error, LocalizedError {
    case missingExecutable(String)
    case missingDirectory(String)
    case screenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .screenFailed(let status): return "screen exited with \(status)"
        case .missingExecutable(let path): return "no executable at \(path)"
        case .missingDirectory(let path): return "no folder at \(path)"
        }
    }
}

/// Runs harness CLIs through a login shell, so they see the PATH and environment
/// the user's terminal does (MCP servers need node, uv and friends).
public final class ProcessLauncher: RoutineLaunching {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "runner")

    public init() {}

    public func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
            throw LaunchError.missingExecutable(spec.executable)
        }
        guard FileManager.default.fileExists(atPath: spec.workingDirectory) else {
            throw LaunchError.missingDirectory(spec.workingDirectory)
        }
        try FileManager.default.createDirectory(at: spec.log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A continued session appends to its log; a new run starts one.
        if spec.resume == nil || !FileManager.default.fileExists(atPath: spec.log.path) {
            FileManager.default.createFile(atPath: spec.log.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: spec.log)
        output.seekToEndOfFile()
        Self.log.info("Starting \(spec.executable, privacy: .public) in \(spec.workingDirectory, privacy: .public)")
        let journal = Self.journal(for: spec, output: output, events: events)
        journal.record(.user, spec.prompt)
        switch spec.mode {
        case .claudeStream:
            if let notice = spec.notice { journal.line("[rota: \(notice)]") }
            return try ClaudeStreamRun.start(spec, journal: journal)
        case .claudeInteractive:
            return try ClaudeInteractiveRun.start(spec, journal: journal)
        case .codexDaemon:
            return CodexDaemonRun.start(spec, journal: journal)
        case .grokACP:
            return GrokACPRun.start(spec, journal: journal)
        case .screen:
            return try ScreenRun.start(spec, journal: journal)
        }
    }

    /// Presentation storage is optional: damaged chat history must not prevent
    /// a harness session from continuing, and must never be overwritten.
    static func journal(for spec: LaunchSpec, output: FileHandle, events: RunEvents) -> RunJournal {
        let url = TranscriptReader.journalURL(for: spec.log)
        guard spec.mode != .screen, spec.resume == nil || FileManager.default.fileExists(atPath: url.path) else {
            return RunJournal(output: output, events: events)
        }
        do {
            let transcript = try TranscriptJournal(log: spec.log, resuming: spec.resume != nil,
                                                   logSize: output.offsetInFile)
            return RunJournal(output: output, events: events, transcript: transcript)
        } catch {
            let journal = RunJournal(output: output, events: events)
            journal.line("[error] Couldn't open chat history. This run will use the readable log.")
            Self.log.error("Couldn't open normalized chat history")
            return journal
        }
    }

    /// Where a shared helper starts: Codex's app-server daemon and Grok's leader
    /// outlive the run that starts them and take its folder and environment for
    /// good. Started in a routine's folder, a leader whose folder was later
    /// deleted could not start an `npx` MCP server for any session (Node's
    /// `uv_cwd` fails), so they start in the home folder with Rota's own
    /// environment, and each session gets its folder and variables over the protocol.
    static var helperDirectory: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// The run's own variables (`ROTA_SESSION`, `ROTA_ROUTINE`, `ROTA_CLI`).
    static func sessionVariables(_ environment: [String: String]) -> [String: String] {
        environment.filter { $0.key.hasPrefix("ROTA_") }
    }

    /// A `Process` that runs `executable arguments` inside `zsh -l`.
    static func loginShellProcess(_ executable: String, _ arguments: [String], in directory: String,
                                  environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\"", executable] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = baseEnvironment().merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// What a run starts from before its login shell reads the user's profile: the
    /// account's own variables, never those of whatever started Rota. Started by
    /// `rota` from inside an agent session, Rota inherited that session's
    /// `CLAUDECODE`, `ANTHROPIC_BASE_URL` and super.engineering variables, and every
    /// routine ran inside them; a run now sees what a new Terminal window sees.
    static func baseEnvironment(_ inherited: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        let kept: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                                 "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"]
        var base = inherited.filter { kept.contains($0.key) || $0.key == "ROTA_DATA_DIR" }
        base["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return base
    }

    /// Runs a short command to completion and returns its exit status and output,
    /// stderr included unless `errors` is false. A command still running after
    /// `timeout` is terminated, so a CLI waiting on a prompt cannot hang the caller.
    /// `loginShell: false` runs an absolute-path system tool directly: a login
    /// shell costs about 0.17 s against 0.04 s, which a once-a-second poll pays
    /// for the whole run.
    static func capture(_ executable: String, _ arguments: [String], in directory: String,
                        timeout: TimeInterval? = nil, errors: Bool = true,
                        loginShell: Bool = true) -> (Int32, String) {
        let process: Process
        if loginShell {
            process = loginShellProcess(executable, arguments, in: directory, environment: [:])
        } else {
            process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.environment = baseEnvironment()
            process.standardInput = FileHandle.nullDevice
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errors ? pipe : FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, lossyUTF8(data))
    }
}

/// Decodes log bytes, replacing invalid sequences: a log read from an arbitrary
/// offset can start mid-character, and a failable decode would drop it whole.
public func lossyUTF8<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: bytes, as: UTF8.self)
}

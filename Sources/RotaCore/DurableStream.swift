import Foundation
import Darwin

/// A private stdout spool survives the host. The owned wrapper persists the actual CLI exit code.
/// All reads and callbacks belong to the runner's serial queue.
final class DurableStream: @unchecked Sendable {
    let process: Process?
    private let lease: RunLease
    private let source: URL
    private let exitFile: URL
    private var offset: UInt64 = 0
    private var lineStart: UInt64 = 0
    private var pending = Data()
    private var finished = false
    private var stopping: [OwnedProcess] = []

    static func folder(_ log: URL) -> URL { log.appendingPathExtension("streams") }

    init(spec: LaunchSpec, arguments: [String]) throws {
        let id = UUID().uuidString
        let folder = Self.folder(spec.log)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        source = folder.appendingPathComponent(id + ".jsonl")
        exitFile = folder.appendingPathComponent(id + ".exit")
        FileManager.default.createFile(atPath: source.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: source)
        defer { try? output.close() }
        let process = ProcessLauncher.loginShellProcess(spec.executable, arguments,
            in: spec.workingDirectory, environment: spec.environment)
        process.arguments = ["-lc", "\"$@\"; rota_status=$?; print -r -- $rota_status > \"$0\"; exit $rota_status",
                             exitFile.path, spec.executable] + arguments
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        process.standardInput = input
        self.process = process
        try process.run()
        do { lease = try RunLease.save(process, log: spec.log, id: id) } catch {
            let owned = OwnedProcess(pid: process.processIdentifier)
            for child in owned?.descendants() ?? [] { child.signal(SIGKILL) }
            process.terminate()
            throw error
        }
    }

    init(restoring log: URL) throws {
        guard let lease = RunLease.read(log), UUID(uuidString: lease.id) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.lease = lease
        process = nil
        source = Self.folder(log).appendingPathComponent(lease.id + ".jsonl")
        exitFile = Self.folder(log).appendingPathComponent(lease.id + ".exit")
    }

    var input: FileHandle? { (process?.standardInput as? Pipe)?.fileHandleForWriting }
    var alive: Bool {
        (process?.isRunning ?? lease.process?.exists ?? false) || stopping.contains { $0.exists }
    }

    func follow(on queue: DispatchQueue, line: @escaping @Sendable (Data, String) -> Void,
                ended: @escaping @Sendable (Int32) -> Void) {
        guard !finished else { return }
        do {
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            guard try file.seekToEnd() >= offset else { throw CocoaError(.fileReadCorruptFile) }
            try file.seek(toOffset: offset)
            while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
                offset += UInt64(bytes.count)
                pending.append(bytes)
                while let newline = pending.firstIndex(of: 10) {
                    let data = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    line(data, lease.id + "/\(lineStart)")
                    lineStart += UInt64(data.count + 1)
                }
            }
        } catch {
            finished = true
            ended(-1)
            return
        }
        if !alive {
            if !pending.isEmpty { line(pending, lease.id + "/\(lineStart)"); pending.removeAll() }
            finished = true
            let value = try? String(contentsOf: exitFile, encoding: .utf8)
            let status = value.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ended(status ?? -1)
        } else {
            queue.asyncAfter(deadline: .now() + 0.1) { self.follow(on: queue, line: line, ended: ended) }
        }
    }

    func stop(on queue: DispatchQueue, delay: TimeInterval = 3) {
        guard let root = lease.process else { return }
        let owned = root.descendants() + [root]
        stopping = owned
        for process in owned { process.signal(SIGTERM) }
        queue.asyncAfter(deadline: .now() + delay) { for process in owned { process.signal(SIGKILL) } }
    }
}

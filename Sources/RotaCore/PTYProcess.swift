import Darwin
import Foundation
import RotaPTY

/// Owns a controlling terminal and its process group. No polling subprocesses or exit files.
final class PTYProcess: @unchecked Sendable {
    let pid: pid_t
    private let terminalFD: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var writer: PipeWriter?
    private var closed = false
    var output: ((Data) -> Void)?
    var exited: ((Int32) -> Void)?
    var inputFailed: (() -> Void)?

    init(executable: String, arguments: [String], directory: String, environment: [String: String],
         queue: DispatchQueue) throws {
        self.queue = queue
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var descriptor: Int32 = -1
        var failure: Int32 = 0
        let child = executable.withCString { program in
            directory.withCString { directory in
                argv.withUnsafeBufferPointer { argv in
                    envp.withUnsafeBufferPointer { envp in
                        rota_pty_spawn(program, argv.baseAddress, envp.baseAddress, directory, &descriptor, &failure)
                    }
                }
            }
        }
        guard child >= 0 else {
            throw ControlError("Could not start the terminal: " + String(cString: strerror(failure)))
        }
        pid = child
        terminalFD = descriptor
        let input = dup(descriptor)
        guard input >= 0 else {
            let failure = errno
            kill(-child, SIGKILL)
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            Darwin.close(descriptor)
            throw ControlError("Could not open terminal input: " + String(cString: strerror(failure)))
        }
        let writer = PipeWriter(FileHandle(fileDescriptor: input, closeOnDealloc: true))
        writer.failed = { [weak self] in
            self?.queue.async { [weak self] in
                self?.inputFailed?()
                self?.terminate()
            }
        }
        self.writer = writer
    }

    /// Start only after callbacks are installed, including for children that exit immediately.
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: terminalFD, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { [terminalFD] in Darwin.close(terminalFD) }
        reader = source
        source.resume()
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(self.pid, &status, 0) < 0 {
                if errno != EINTR { status = 1 << 8; break }
            }
            let code = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            self.queue.async {
                self.read()
                self.exited?(code)
                self.close()
            }
        }
    }

    @discardableResult
    func write(_ data: Data, completed: (() -> Void)? = nil) -> Bool {
        guard !closed, let writer else { return false }
        writer.send(data, completed: completed)
        return true
    }

    func resize(rows: UInt16, columns: UInt16) {
        guard !closed, rows > 0, columns > 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(terminalFD, TIOCSWINSZ, &size)
    }

    func terminate() { if !closed { kill(-pid, SIGTERM) } }
    func forceKill() { if !closed { kill(-pid, SIGKILL) } }

    private func read() {
        guard !closed else { return }
        // Both descriptor copies stay nonblocking; output callbacks can enqueue input safely.
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(terminalFD, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            output?(Data(bytes.prefix(count)))
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        writer?.close()
        writer = nil
        reader?.cancel()
        reader = nil
    }
}

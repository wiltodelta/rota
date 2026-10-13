import Darwin
import Foundation
import RotaPTY

/// Owns a controlling terminal and its process group. No polling subprocesses or exit files.
final class PTYProcess: @unchecked Sendable {
    let pid: pid_t
    private let terminalFD: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var closed = false
    var output: ((Data) -> Void)?
    var exited: ((Int32) -> Void)?

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
    func write(_ data: Data) -> Bool {
        guard !closed else { return false }
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(terminalFD, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
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
        // Nonblocking only while draining; writes retain their complete-message semantics.
        let flags = fcntl(terminalFD, F_GETFL)
        _ = fcntl(terminalFD, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(terminalFD, F_SETFL, flags) }
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
        reader?.cancel()
        reader = nil
    }
}

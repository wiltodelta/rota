import Darwin
import Foundation

/// A private attachment socket forwards terminal bytes without giving up PTY ownership.
final class PTYTerminal: @unchecked Sendable {
    let path: String
    private let process: PTYProcess
    private let queue: DispatchQueue
    private var listener: DispatchSourceRead?
    private var client: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var descriptor: Int32 = -1
    private var input = Data()
    private var output = Data()
    private var replay = Data()

    init(process: PTYProcess, queue: DispatchQueue, folder: URL) throws {
        self.process = process
        self.queue = queue
        path = folder.appendingPathComponent(UUID().uuidString + ".sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("Could not create terminal socket.") }
        var address = try ControlServer.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            unlink(path)
            throw ControlError("Could not listen on the terminal socket.")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    func publish(_ data: Data) {
        replay.append(data)
        if replay.count > 65_536 { replay.removeFirst(replay.count - 65_536) }
        guard descriptor >= 0 else { return }
        output.append(data)
        // A stopped terminal reader must never hold up the agent's terminal.
        guard output.count <= 524_288 else { return detach() }
        flush()
    }

    func close() {
        detach()
        listener?.cancel()
        listener = nil
        unlink(path)
    }

    private func accept(_ fd: Int32) {
        let incoming = Darwin.accept(fd, nil, nil)
        guard incoming >= 0 else { return }
        guard client == nil else { Darwin.close(incoming); return }
        _ = fcntl(incoming, F_SETFL, O_NONBLOCK)
        FileDescriptorIO.suppressBrokenPipe(incoming)
        descriptor = incoming
        let source = DispatchSource.makeReadSource(fileDescriptor: incoming, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { Darwin.close(incoming) }
        client = source
        source.resume()
        output = replay
        flush()
    }

    private func read() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else { return detach() }
        input.append(contentsOf: bytes.prefix(count))
        guard input.count <= 65_536 else { return detach() }
        while let newline = input.firstIndex(of: 10) {
            let line = Data(input.prefix(upTo: newline))
            input.removeSubrange(input.startIndex...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let rows = message["rows"] as? UInt16, let columns = message["columns"] as? UInt16 {
                process.resize(rows: rows, columns: columns)
            }
            if let value = message["input"] as? String, let data = Data(base64Encoded: value) {
                _ = process.write(data)
            }
        }
    }

    private func flush() {
        guard descriptor >= 0 else { return }
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writer = source
                    source.resume()
                }
                return
            }
            guard count > 0 else { return detach() }
            output.removeFirst(count)
        }
        writer?.cancel()
        writer = nil
    }

    private func detach() {
        writer?.cancel()
        writer = nil
        client?.cancel()
        client = nil
        descriptor = -1
        input = Data()
        output = Data()
    }
}

/// `rota attach-terminal` restores the local terminal on every normal exit. Ctrl-] detaches.
public enum TerminalAttachment {
    public static func attach(_ path: String) throws {
        guard isatty(STDIN_FILENO) == 1 else { throw ControlError("Terminal attachment requires a terminal.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("Could not create attachment socket.") }
        defer { Darwin.close(fd) }
        FileDescriptorIO.suppressBrokenPipe(fd)
        var address = try ControlServer.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ControlError("The terminal session has ended.") }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw ControlError("Could not read terminal settings.") }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw ControlError("Could not enter terminal mode.") }
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        var oldSize = winsize()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            try resize(fd, previous: &oldSize)
            var descriptors = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, 2, 200)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw ControlError("Terminal connection failed.") }
            if descriptors[0].revents != 0, try !forwardOutput(fd, bytes: &bytes) { return }
            if descriptors[1].revents != 0, try !forwardInput(fd, bytes: &bytes) { return }

        }
    }

    private static func resize(_ fd: Int32, previous: inout winsize) throws {
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
        if size.ws_row != previous.ws_row || size.ws_col != previous.ws_col {
            try send(["rows": size.ws_row, "columns": size.ws_col], to: fd)
            previous = size
        }
    }

    private static func forwardOutput(_ fd: Int32, bytes: inout [UInt8]) throws -> Bool {
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else { return false }
        try FileHandle.standardOutput.write(contentsOf: Data(bytes.prefix(count)))
        return true
    }

    private static func forwardInput(_ fd: Int32, bytes: inout [UInt8]) throws -> Bool {
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        guard count > 0 else { return false }
        if let detach = bytes.prefix(count).firstIndex(of: 0x1D) {
            if detach > 0 { try send(["input": Data(bytes.prefix(detach)).base64EncodedString()], to: fd) }
            return false
        }
        try send(["input": Data(bytes.prefix(count)).base64EncodedString()], to: fd)
        return true
    }

    private static func send(_ message: [String: Any], to fd: Int32) throws {
        let data = try JSONSerialization.data(withJSONObject: message) + Data([10])
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
    }
}

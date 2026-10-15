import Darwin
import Foundation

/// A run's private, deferred control endpoint. All callbacks and connections stay on its runner queue.
final class ClaudeHookServer: @unchecked Sendable {
    let path: String
    var received: ((String, [String: Any], @escaping ([String: Any]) -> Void) -> Void)?
    var disconnected: ((String) -> Void)?
    private let queue: DispatchQueue
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    private final class Client {
        let id = UUID().uuidString
        var source: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var input = Data()
        var output = Data()
        var submitted = false
        var replied = false
    }

    init(folder: URL, queue: DispatchQueue) throws {
        self.queue = queue
        path = folder.appendingPathComponent(UUID().uuidString + ".sock").path
        var address = try ControlServer.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("Could not create the Claude hook socket.") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            unlink(path)
            throw ControlError("Could not listen on the Claude hook socket.")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    /// Called on the runner queue after its pending requests have been denied.
    func close() {
        for fd in Array(clients.keys) { disconnect(fd) }
        listener?.cancel()
        listener = nil
        unlink(path)
    }

    private func accept(_ listener: Int32) {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        FileDescriptorIO.suppressBrokenPipe(fd)
        let client = Client()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        client.source = source
        clients[fd] = client
        source.resume()
    }

    private func read(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0, !client.submitted else { return disconnect(fd) }
        client.input.append(contentsOf: chunk.prefix(count))
        guard client.input.count <= 4_000_000 else { return disconnect(fd) }
        guard let newline = client.input.firstIndex(of: 10) else { return }
        guard let message = try? JSONSerialization.jsonObject(with: Data(client.input.prefix(upTo: newline)))
            as? [String: Any], message["method"] as? String == "claude-hook",
              let params = message["params"] as? [String: Any], let received else { return disconnect(fd) }
        client.submitted = true
        client.input = Data()
        let identity = message["id"] ?? NSNull()
        received(client.id, params) { [weak self, weak client] value in
            guard let self, let client, self.clients[fd] === client, !client.replied else { return }
            client.replied = true
            client.output = (try? JSONSerialization.data(withJSONObject: ["id": identity, "result": value])) ?? Data()
            client.output.append(10)
            self.flush(fd)
        }
    }

    private func flush(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        while !client.output.isEmpty {
            let count = client.output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                if client.writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush(fd) }
                    client.writer = source
                    source.resume()
                }
                return
            }
            guard count > 0 else { return disconnect(fd) }
            client.output.removeFirst(count)
        }
        disconnect(fd)
    }

    private func disconnect(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.writer?.cancel()
        client.source?.cancel()
        disconnected?(client.id)
    }
}

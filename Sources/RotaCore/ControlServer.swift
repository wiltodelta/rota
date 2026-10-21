import Darwin
import Foundation
import os

/// A failed control request, with the sentence the caller shows.
public struct ControlError: Error, Equatable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The socket other processes reach the running app through: the `rota`
/// command and its MCP server. One JSON object per line each way,
/// `{"id", "method", "params"}` in and `{"id", "result"}` or
/// `{"id", "error": {"message"}}` out. The socket is the user's alone (0600):
/// whoever can write to it can run routines.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @MainActor (String, [String: Any]) async -> Result<Any, ControlError>

    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "control")
    public static var standardSocket: URL { StorageLocation.standard.root.appendingPathComponent("rota.sock") }

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.control")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: ControlConnection] = [:]

    public init(socket: URL = ControlServer.standardSocket, handler: @escaping Handler) {
        path = socket.path
        self.handler = handler
    }

    /// Diagnostic snapshot, also used to prove descriptor reuse in socket regression tests.
    var connectedDescriptors: [Int32] { queue.sync { Array(connections.keys) } }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError("Could not create the control socket.") }
        var address: sockaddr_un
        do { address = try Self.address(path) } catch { close(descriptor); throw error }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw ControlError("Could not listen on \(path): \(String(cString: strerror(errno))).")
        }
        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        acceptSource = source
        Self.log.info("Listening on \(self.path, privacy: .public)")
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            connections.values.forEach { $0.cancel() }
            connections = [:]
            if listener >= 0 { close(listener) }
            listener = -1
        }
        unlink(path)
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlError("The socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    // MARK: On `queue`

    private func accept() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        let connection = ControlConnection(descriptor: client, queue: queue)
        connection.reader.setEventHandler { [weak self, weak connection] in
            if let connection { self?.read(connection) }
        }
        connections[client] = connection
        connection.reader.resume()
    }

    private func remove(_ connection: ControlConnection) {
        guard connections[connection.descriptor] === connection else { return }
        connections[connection.descriptor] = nil
        connection.cancel()
    }

    private func read(_ connection: ControlConnection) {
        guard connections[connection.descriptor] === connection else { return }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(connection.descriptor, &chunk, chunk.count)
        if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { return }
        guard count > 0 else { return remove(connection) }
        connection.input.append(contentsOf: chunk[0..<count])
        guard connection.input.count <= 32 * 1024 * 1024 else { return remove(connection) }
        while let newline = connection.input.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(connection.input[..<newline])
            connection.input.removeSubrange(...newline)
            handle(line, from: connection)
        }
    }

    private func handle(_ line: Data, from client: ControlConnection) {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let method = request["method"] as? String else {
            return reply(["error": ["message": "Not a JSON request with a method."]], to: client)
        }
        let boxed = UncheckedSendable(request)
        Task { @MainActor [handler] in
            let id = boxed.value["id"] ?? NSNull()
            let result = await handler(method, boxed.value["params"] as? [String: Any] ?? [:])
            let response: [String: Any]
            switch result {
            case .success(let value): response = ["id": id, "result": value]
            case .failure(let error): response = ["id": id, "error": ["message": error.message]]
            }
            Self.log.info("\(method, privacy: .public): \(error(result), privacy: .public)")
            let reply = UncheckedSendable(response)
            self.queue.async { self.reply(reply.value, to: client) }
        }
    }

    private func reply(_ response: [String: Any], to client: ControlConnection) {
        guard connections[client.descriptor] === client,
              var data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { return }
        data.append(UInt8(ascii: "\n"))
        guard client.enqueue(data), client.flush() else { return remove(client) }
        guard !client.output.isEmpty, client.writer == nil else { return }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: client.descriptor, queue: queue)
        writer.setEventHandler { [weak self, weak client] in
            guard let self, let client, self.connections[client.descriptor] === client else { return }
            if !client.flush() { self.remove(client) }
        }
        client.writer = writer
        writer.resume()
    }
}

private func error(_ result: Result<Any, ControlError>) -> String {
    if case .failure(let error) = result { return error.message }
    return "ok"
}

/// The `rota` command's side of the control socket: one request, one reply.
public enum ControlClient {
    public static func call(_ method: String, _ params: [String: Any] = [:],
                            socket: URL = ControlServer.standardSocket, timeout: TimeInterval = 30) throws -> Any {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError("Could not create a socket.") }
        defer { close(descriptor) }
        var address = try ControlServer.address(socket.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ControlError.notRunning }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let requestID = UUID().uuidString
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var request = try JSONSerialization.data(withJSONObject: ["id": requestID, "method": method, "params": params])
        request.append(UInt8(ascii: "\n"))
        try request.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { throw ControlError("Could not send the request to Rota.") }
                offset += sent
            }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !buffer.contains(UInt8(ascii: "\n")) {
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { throw ControlError("Rota did not answer within \(Int(timeout)) s.") }
            buffer.append(contentsOf: chunk[0..<count])
        }
        guard let response = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] else {
            throw ControlError("Rota's answer was not JSON.")
        }
        guard response["id"] as? String == requestID else {
            throw ControlError("Rota returned an answer for a different request.")
        }
        if let error = response["error"] as? [String: Any] {
            throw ControlError(error["message"] as? String ?? "Rota refused the request.")
        }
        return response["result"] ?? NSNull()
    }
}

public extension ControlError {
    /// No app on the socket: Rota is closed, or an older version without it.
    static let notRunning = ControlError("Rota is not running.")
}

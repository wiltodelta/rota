import Foundation
import CoreFoundation
import CryptoKit

/// Carries whole JSON-RPC messages to and from a peer.
protocol MessageTransport: AnyObject {
    var onMessage: ((Data) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func send(_ message: Data)
    func close()
}

/// A JSON-RPC 2.0 client over a transport: requests with replies, notifications
/// both ways, and requests the peer sends us. Replies, notifications and the close
/// arrive on `callbackQueue` (a run's own serial queue), or on the transport's
/// reading thread without one. Incoming server requests use the same queue.
final class JSONRPCPeer: @unchecked Sendable {
    typealias Reply = (Result<Any, JSONRPCError>) -> Void

    private let transport: MessageTransport
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: Reply] = [:]
    private var isClosed = false
    /// Tests advance request deadlines synchronously; a timeout never retries a remote write.
    var scheduleTimeout: (TimeInterval, @escaping () -> Void) -> Void = { seconds, work in
        let box = UncheckedSendable(work)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { box.value() }
    }
    /// A notification from the peer: method and params.
    var onNotification: ((String, [String: Any]) -> Void)?
    /// A request from the peer; return the result to send, or nil to answer "method not found".
    var onRequest: ((String, [String: Any]) -> Any?)?
    /// Delayed server replies run on callbackQueue and can wait for explicit user input.
    var onAsyncRequest: ((String, [String: Any], String, @escaping (Any?) -> Void) -> Void)?
    var onClose: (() -> Void)?
    private let callbackQueue: DispatchQueue?

    init(transport: MessageTransport, callbackQueue: DispatchQueue? = nil) {
        self.transport = transport
        self.callbackQueue = callbackQueue
        transport.onMessage = { [weak self] data in self?.receive(data) }
        transport.onClose = { [weak self] in self?.closed() }
    }

    /// Keep numeric and string request IDs distinct when a provider resolves a request elsewhere.
    static func requestIdentity(_ value: Any) -> String { EventContent.text([value]) ?? "" }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval? = nil, reply: @escaping Reply) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return deliver { reply(.failure(JSONRPCError(message: "The provider connection has closed."))) }
        }
        let id = nextID
        nextID += 1
        pending[id] = reply
        lock.unlock()
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        if let timeout { scheduleTimeout(timeout) { [weak self] in self?.expire(id) } }
    }

    private func expire(_ id: Int) {
        lock.lock()
        let reply = pending.removeValue(forKey: id)
        lock.unlock()
        deliver {
            let error = JSONRPCError(message: "The provider did not confirm delivery in time.", deliveryUncertain: true)
            reply?(.failure(error))
        }
    }

    func notify(_ method: String, _ params: [String: Any] = [:]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func close() {
        transport.close()
        closed()
    }

    private func write(_ object: [String: Any]) {
        guard lock.withLock({ !isClosed }) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        transport.send(data)
    }

    private func receive(_ data: Data) {
        guard lock.withLock({ !isClosed }) else { return }
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        switch (method, message["id"]) {
        case let (method?, id?):
            let requestID = UncheckedSendable(id)
            let parameters = UncheckedSendable(params)
            let once = RPCServerReply { [weak self] result in
                if let result {
                    self?.write(["jsonrpc": "2.0", "id": requestID.value, "result": result])
                } else {
                    self?.write(["jsonrpc": "2.0", "id": requestID.value,
                                 "error": ["code": -32601, "message": "Rota does not handle \(method)"]])
                }
            }
            deliver {
                if let handler = self.onAsyncRequest {
                    handler(method, parameters.value, Self.requestIdentity(requestID.value), once.send)
                } else {
                    once.send(self.onRequest?(method, parameters.value))
                }
            }
        case let (method?, nil):
            deliver { self.onNotification?(method, params) }
        case let (nil, id as Int):
            if let number = message["id"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return }
            lock.lock()
            let reply = pending.removeValue(forKey: id)
            lock.unlock()
            let result: Result<Any, JSONRPCError> = if let error = message["error"] as? [String: Any] {
                .failure(JSONRPCError(message: error["message"] as? String ?? "error"))
            } else {
                .success(message["result"] ?? NSNull())
            }
            deliver { reply?(result) }
        default:
            break
        }
    }

    private func closed() {
        lock.lock()
        guard !isClosed else { return lock.unlock() }
        isClosed = true
        let waiting = pending.values
        pending.removeAll()
        lock.unlock()
        deliver {
            let error = JSONRPCError(message: "connection closed before the reply", deliveryUncertain: true)
            waiting.forEach { $0(.failure(error)) }
            self.onClose?()
        }
    }

    /// Runs `work` on the callback queue, or right here without one.
    private func deliver(_ work: @escaping () -> Void) {
        guard let callbackQueue else { return work() }
        // Unchecked: the closure carries JSON values parsed on the reading thread,
        // which never touches them again.
        let box = UncheckedSendable(work)
        callbackQueue.async { box.value() }
    }
}

/// A value handed to another queue that the sending side never touches again.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

struct JSONRPCError: Error, LocalizedError {
    let message: String
    var deliveryUncertain: Bool = false
    var errorDescription: String? { message }
}

/// One JSON message per line over a child process's stdin and stdout (ACP's stdio transport).
final class LineTransport: MessageTransport, @unchecked Sendable {
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let writer: PipeWriter
    private let lock = NSLock()
    private var buffer = Data()

    init(input: FileHandle, output: FileHandle) {
        writer = PipeWriter(input)
        writer.failed = { [weak self] in self?.onClose?() }
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.onClose?()
            } else {
                self?.consume(data)
            }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        lines.filter { !$0.isEmpty }.forEach { onMessage?(Data($0)) }
    }

    func send(_ message: Data) {
        writer.send(message + Data("\n".utf8))
    }

    func close() {
        writer.close()
    }
}

/// A WebSocket client over a byte pipe: the handshake and text frames of RFC 6455,
/// as much as a JSON-RPC session needs. Codex's app-server speaks WebSocket on its
/// Unix socket, and `codex app-server proxy` hands us that socket as stdin/stdout.
final class WebSocketTransport: MessageTransport, @unchecked Sendable {
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let writer: PipeWriter
    private let expectedAccept: String
    private let lock = NSLock()
    private var buffer = Data()
    private var upgraded = false
    private var queued: [Data] = []
    private var fragments = Data()

    init(input: FileHandle, output: FileHandle, key: String? = nil) {
        let key = key ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        expectedAccept = Data(Insecure.SHA1.hash(data: Data(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        writer = PipeWriter(input)
        writer.failed = { [weak self] in self?.onClose?() }
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.onClose?()
            } else {
                self?.consume(data)
            }
        }
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        writer.send(Data(handshake.utf8))
    }

    func send(_ message: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard upgraded else { return queued.append(message) }
        writer.send(Self.frame(message, opcode: 0x1))
    }

    func close() {
        lock.lock()
        writer.send(Self.frame(Data(), opcode: 0x8))
        lock.unlock()
        writer.close()
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        if !upgraded {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return lock.unlock() }
            let head = lossyUTF8(buffer[buffer.startIndex..<end.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            guard Self.validUpgrade(head, expectedAccept: expectedAccept) else {
                lock.unlock()
                return onClose?() ?? ()
            }
            upgraded = true
            for message in queued { writer.send(Self.frame(message, opcode: 0x1)) }
            queued.removeAll()
        }
        var messages: [Data] = []
        while let frame = Self.parse(buffer) {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + frame.length)
            switch frame.opcode {
            case 0x0, 0x1:
                fragments.append(frame.payload)
                if frame.final {
                    messages.append(fragments)
                    fragments = Data()
                }
            case 0x9:
                writer.send(Self.frame(frame.payload, opcode: 0xA))
            case 0x8:
                writer.send(Self.frame(frame.payload, opcode: 0x8))
                writer.close()
                lock.unlock()
                return onClose?() ?? ()
            default:
                break
            }
        }
        lock.unlock()
        messages.forEach { onMessage?($0) }
    }

    static func validUpgrade(_ head: String, expectedAccept: String) -> Bool {
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ") ?? []
        guard status.count >= 2, status[0] == "HTTP/1.1", status[1] == "101" else { return false }
        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return false }
            fields[String(parts[0]).lowercased(), default: []].append(
                String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
        let connections = fields["connection", default: []].joined(separator: ",").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return fields["upgrade"]?.map { $0.lowercased() } == ["websocket"]
            && connections.contains("upgrade") && fields["sec-websocket-accept"] == [expectedAccept]
    }

    /// A client frame: final, masked, with the length in the smallest form.
    static func frame(_ payload: Data, opcode: UInt8) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= UInt16.max {
            frame.append(0x80 | 126)
            frame.append(contentsOf: withUnsafeBytes(of: UInt16(count).bigEndian, Array.init))
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: withUnsafeBytes(of: UInt64(count).bigEndian, Array.init))
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    struct Frame {
        var opcode: UInt8
        var final: Bool
        var payload: Data
        /// Bytes the frame takes in the stream, header included.
        var length: Int
    }

    /// One complete server frame at the start of `data`, or nil until it has all arrived.
    static func parse(_ data: Data) -> Frame? {
        let bytes = [UInt8](data.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let final = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            let extended = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard extended <= UInt64(Int.max - 14) else { return nil }
            length = Int(extended)
            offset = 10
        }
        let maskOffset = offset
        if masked { offset += 4 }
        guard data.count >= offset + length else { return nil }
        let start = data.startIndex + offset
        var payload = Data(data[start..<start + length])
        if masked {
            let mask = [UInt8](data[data.startIndex + maskOffset..<data.startIndex + maskOffset + 4])
            payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        return Frame(opcode: opcode, final: final, payload: payload, length: offset + length)
    }
}

/// A deferred reply may race cancellation; only one result is ever put on the wire.
private final class RPCServerReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Any?) -> Void)?
    init(_ reply: @escaping (Any?) -> Void) { self.reply = reply }
    func send(_ value: Any?) {
        lock.lock()
        let work = reply
        reply = nil
        lock.unlock()
        work?(value)
    }
}

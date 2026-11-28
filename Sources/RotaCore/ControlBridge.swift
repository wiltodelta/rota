internal import CRotaFFI
import Foundation

public struct ControlError: Error, Equatable, LocalizedError, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

private let controlServerHandlers = FFICallbackRegistry<ControlServer.Handler>()

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

private func controlRequestTrampoline(
    ctx: UInt,
    methodPtr: UnsafePointer<CChar>?,
    paramsPtr: UnsafePointer<CChar>?,
    replyCtx: UInt,
    replyFn: RotaControlReplyFn?
) {
    guard let replyFn else { return }
    guard let handler = controlServerHandlers.lookup(ctx),
          let methodPtr else {
        "{\"error\":\"Control server stopped.\"}".withCString { replyFn(replyCtx, $0) }
        return
    }
    let method = String(cString: methodPtr)
    let rawParams = paramsPtr.map { String(cString: $0) } ?? "{}"
    let parsed = (try? JSONSerialization.jsonObject(with: Data(rawParams.utf8))) as? [String: Any] ?? [:]
    let boxedParams = UncheckedBox(value: parsed)
    Task { @MainActor in
        let outcome = await handler(method, boxedParams.value)
        let responseObj: [String: Any]
        switch outcome {
        case .success(let val):
            responseObj = ["ok": val]
        case .failure(let err):
            responseObj = ["error": err.message]
        }
        let encoded = FFIJSON.encodeParams(responseObj)
        encoded.withCString { replyFn(replyCtx, $0) }
    }
}

/// Unix domain socket control server backed by `rota-core`'s `ControlServer`.
/// Guards its handle with an internal lock and is `@unchecked Sendable`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @MainActor (String, [String: Any]) async -> Result<Any, ControlError>

    public static var standardSocket: URL {
        StorageLocation.standard.root.appendingPathComponent("rota.sock")
    }

    private let socketURL: URL
    private let handler: Handler
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var token: UInt = 0

    public init(socket: URL = ControlServer.standardSocket, handler: @escaping Handler) {
        self.socketURL = socket
        self.handler = handler
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { return }
        let id = controlServerHandlers.register(handler)
        var errPtr: UnsafeMutablePointer<CChar>?
        let created = socketURL.path.withCString { sockPtr in
            rota_control_server_start(sockPtr, id, controlRequestTrampoline, &errPtr)
        }
        guard let created else {
            controlServerHandlers.unregister(id)
            let message = FFIJSON.string(taking: errPtr) ?? "Could not start control server."
            throw ControlError(message)
        }
        token = id
        handle = created
    }

    public func stop() {
        lock.lock()
        let current = handle
        let id = token
        handle = nil
        token = 0
        lock.unlock()
        if id != 0 {
            controlServerHandlers.unregister(id)
        }
        if let current {
            rota_control_server_free(current)
        }
    }

    deinit {
        stop()
    }
}

public enum ControlCLI {
    public struct Arguments: Sendable {
        public let raw: [String]

        public init(_ raw: [String]) {
            self.raw = raw
        }
    }

    public static func request(_ command: String, _ arguments: Arguments) throws -> (String, [String: Any]) {
        do {
            let val = try FFIBridge.callCoreRaw("control.cliRequest", params: [
                "command": command,
                "arguments": arguments.raw
            ])
            guard let dict = val as? [String: Any],
                  let method = dict["method"] as? String else {
                throw ControlError("Invalid CLI request response.")
            }
            let params = dict["params"] as? [String: Any] ?? [:]
            return (method, params)
        } catch let err as FFICallError {
            throw ControlError(err.message)
        }
    }
}

public enum ControlClient {
    public static func call(
        _ method: String,
        _ params: [String: Any] = [:],
        socket: URL = ControlServer.standardSocket,
        timeout: TimeInterval = 5
    ) throws -> Any {
        do {
            return try FFIBridge.callCoreRaw("control.clientCall", params: [
                "method": method,
                "params": params,
                "socket": socket.path,
                "timeoutSecs": timeout
            ])
        } catch let err as FFICallError {
            throw ControlError(err.message)
        }
    }
}

internal import CRotaFFI
import Foundation

enum FFIDateCoding {
    private static let lock = NSLock()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func format(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: text) ?? standard.date(from: text)
    }
}

final class FFICallbackRegistry<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt = 1
    private var entries: [UInt: Value] = [:]

    func register(_ value: Value) -> UInt {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID &+= 1
        entries[id] = value
        return id
    }

    func lookup(_ id: UInt) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    func unregister(_ id: UInt) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: id)
    }
}

struct FFIEnvelope<Value: Decodable>: Decodable {
    var ok: Value?
    var error: String?
}

enum FFIJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, target in
            var container = target.singleValueContainer()
            try container.encode(FFIDateCoding.format(date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let text = try container.decode(String.self)
            guard let parsed = FFIDateCoding.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 timestamp: \(text)"
                )
            }
            return parsed
        }
        return decoder
    }()

    static func string(taking ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { rota_string_free(ptr) }
        return String(cString: ptr)
    }

    static func toJSONValue<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func encodeParams(_ dict: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try decoder.decode(type, from: data)
    }
}

struct FFICallError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

enum FFIBridge {
    static func callCoreRaw(_ method: String, params: [String: Any] = [:]) throws -> Any {
        let jsonParams = FFIJSON.encodeParams(params)
        let raw = method.withCString { methodPtr in
            jsonParams.withCString { paramsPtr in
                FFIJSON.string(taking: rota_core_call(methodPtr, paramsPtr))
            }
        }
        guard let raw,
              let envelope = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            throw FFICallError(message: "Invalid response from Rust core for \(method).")
        }
        if let err = envelope["error"] as? String {
            throw FFICallError(message: err)
        }
        return envelope["ok"] ?? NSNull()
    }

    static func callCore<T: Decodable>(_ type: T.Type, _ method: String, params: [String: Any] = [:]) throws -> T {
        let jsonParams = FFIJSON.encodeParams(params)
        let raw = method.withCString { methodPtr in
            jsonParams.withCString { paramsPtr in
                FFIJSON.string(taking: rota_core_call(methodPtr, paramsPtr))
            }
        }
        guard let raw else {
            throw FFICallError(message: "Empty response from Rust core for \(method).")
        }
        let envelope = try FFIJSON.decoder.decode(FFIEnvelope<T>.self, from: Data(raw.utf8))
        if let err = envelope.error {
            throw FFICallError(message: err)
        }
        if let ok = envelope.ok {
            return ok
        }
        return try FFIJSON.decoder.decode(type, from: Data("null".utf8))
    }
}

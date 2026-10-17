import Foundation

/// Claude's own configuration resolver. Control requests send no prompt and spend no model quota.
/// Read off the UI actor; a lock protects replies and the semaphore bounds the wait.
public struct ClaudeConfiguration: Sendable {
    public var session: SessionConfiguration
    public var models: [ModelOption]

    static let settingsID = "rota-settings"
    static let initializeID = "rota-initialize"

    static func request(_ subtype: String, id: String) -> Data {
        let value: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": subtype]]
        return ((try? JSONSerialization.data(withJSONObject: value)) ?? Data()) + Data([10])
    }

    static func applied(_ event: [String: Any]) -> SessionConfiguration? {
        guard event["type"] as? String == "control_response",
              let response = event["response"] as? [String: Any],
              response["request_id"] as? String == settingsID, response["subtype"] as? String == "success",
              let payload = response["response"] as? [String: Any],
              let applied = payload["applied"] as? [String: Any], let model = applied["model"] as? String else {
            return nil
        }
        // Explicit null means the CLI will send no effort parameter, not an unknown default.
        let effort = applied["effort"] is NSNull ? "none" : applied["effort"] as? String
        return SessionConfiguration(model: model, effort: effort)
    }

    public static func read(executable: String, directory: String, model: String? = nil,
                            effort: String? = nil, resume: String? = nil, timeout: TimeInterval = 8)
        -> ClaudeConfiguration? {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--no-session-persistence"]
        for (flag, value) in [("--model", model), ("--effort", effort), ("--resume", resume)] {
            if let value { arguments += [flag, value] }
        }
        let process = ProcessLauncher.loginShellProcess(executable, arguments, in: directory, environment: [:])
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let transport = LineTransport(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var configuration: SessionConfiguration?
        var models: [ModelOption] = []
        var initialized = false
        transport.onClose = { done.signal() }
        transport.onMessage = { data in
            guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            lock.lock()
            defer { lock.unlock() }
            if let applied = applied(event) { configuration = applied }
            if let response = event["response"] as? [String: Any],
               response["request_id"] as? String == initializeID {
                initialized = true
                models = ModelCatalog.parseClaudeModels(response["response"] ?? [:])
            }
            if initialized && configuration != nil { done.signal() }
        }
        defer {
            transport.close()
            if process.isRunning { process.terminate() }
            if process.processIdentifier > 0 { process.waitUntilExit() }
        }
        do { try process.run() } catch { return nil }
        // LineTransport already appends its own newline.
        transport.send(request("initialize", id: initializeID).dropLast())
        transport.send(request("get_settings", id: settingsID).dropLast())
        _ = done.wait(timeout: .now() + timeout)
        return lock.withLock {
            configuration.map { ClaudeConfiguration(session: $0, models: models) }
        }
    }
}

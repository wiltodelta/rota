import Foundation
import os

extension ModelCatalog {
    /// The Agent SDK initialization handshake lists choices without submitting a
    /// user message. Keep stdin open until the correlated control response arrives.
    static func claudeModels(executable: String, timeout: TimeInterval = 10) -> [ModelOption] {
        let logger = Logger(subsystem: "com.wiltodelta.rota", category: "models")
        let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                         "--settings", "{\"disableAllHooks\":true}", "--no-session-persistence"]
        let process = ProcessLauncher.loginShellProcess(executable, arguments, in: NSTemporaryDirectory(),
                                                       environment: [:])
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let transport = LineTransport(input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var models: [ModelOption] = []
        let requestID = UUID().uuidString
        transport.onMessage = { data in
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any],
                  response["request_id"] as? String == requestID else { return }
            if response["subtype"] as? String == "success" {
                lock.lock()
                models = parseClaudeModels(response["response"] as Any)
                lock.unlock()
            }
            done.signal()
        }
        transport.onClose = { done.signal() }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            transport.close()
            if process.isRunning { process.terminate() }
        }
        do { try process.run() } catch {
            logger.warning("Claude model catalog could not start: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let request: [String: Any] = ["type": "control_request", "request_id": requestID,
                                      "request": ["subtype": "initialize", "hooks": NSNull()]]
        if let data = try? JSONSerialization.data(withJSONObject: request) { transport.send(data) }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        let result = models
        lock.unlock()
        if result.isEmpty { logger.warning("Claude model catalog unavailable") }
        return result
    }

    /// Preserve the CLI's choice IDs: current-family aliases remain aliases, while
    /// older versions have explicit IDs. Display names include resolved versions.
    static func parseClaudeModels(_ value: Any) -> [ModelOption] {
        let rows = (value as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let defaultModel = rows.first { $0["value"] as? String == "default" }?["resolvedModel"] as? String
        return rows.compactMap { row in
            guard let id = row["value"] as? String, !id.isEmpty, id != "default" else { return nil }
            let efforts = row["supportsEffort"] as? Bool == true
                ? row["supportedEffortLevels"] as? [String] ?? [] : []
            return ModelOption(id: id, title: row["displayName"] as? String ?? id, efforts: efforts,
                               isDefault: defaultModel != nil && row["resolvedModel"] as? String == defaultModel)
        }
    }
}

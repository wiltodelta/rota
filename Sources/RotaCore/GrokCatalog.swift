import Foundation
import os

/// `initialize` exposes model metadata without creating a session or asking a model.
enum GrokCatalog {
    static func read(executable: String, timeout: TimeInterval = 10) -> [ModelOption]? {
        let process = ProcessLauncher.loginShellProcess(executable, ["agent", "--no-leader", "stdio"],
            in: ProcessLauncher.helperDirectory, environment: [:])
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let peer = JSONRPCPeer(transport: LineTransport(input: input.fileHandleForWriting,
                                                       output: output.fileHandleForReading))
        let models = OSAllocatedUnfairLock<[ModelOption]?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        peer.onClose = { done.signal() }
        peer.request("initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any]()]) { result in
            if case .success(let value) = result, let metadata = (value as? [String: Any])?["_meta"] as? [String: Any] {
                let parsed = parse(metadata["modelState"])
                models.withLock { $0 = parsed }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        peer.close()
        if process.isRunning { process.terminate() }
        return models.withLock { $0 }
    }

    static func parse(_ value: Any?) -> [ModelOption]? {
        guard let state = value as? [String: Any], let rows = state["availableModels"] as? [[String: Any]],
              !rows.isEmpty else { return nil }
        return rows.compactMap { row in
            guard let id = row["modelId"] as? String else { return nil }
            let metadata = row["_meta"] as? [String: Any] ?? [:]
            let efforts = (metadata["reasoningEfforts"] as? [[String: Any]] ?? []).compactMap {
                $0["value"] as? String ?? $0["id"] as? String
            }
            return ModelOption(id: id, title: row["name"] as? String ?? id,
                               efforts: metadata["supportsReasoningEffort"] as? Bool == true ? efforts : [],
                               isDefault: state["currentModelId"] as? String == id)
        }
    }
}

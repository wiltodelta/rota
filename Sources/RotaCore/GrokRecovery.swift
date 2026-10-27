import Foundation

/// session/load coalesces chunks; the archive also preserves background activity and final stop reasons.
struct GrokRecovery {
    var activity = GrokActivity()
    var outcome: RunOutcome?

    init(session: String) {
        guard let source = NativeTranscript.locate(.grok, session: session),
              let file = try? FileHandle(forReadingFrom: source) else { return }
        defer { try? file.close() }
        var pending = Data()
        while let bytes = try? file.read(upToCount: 65_536), !bytes.isEmpty {
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let params = row["params"] as? [String: Any], params["sessionId"] as? String == session,
                      let update = params["update"] as? [String: Any] else { continue }
                _ = activity.apply(update)
                if update["sessionUpdate"] as? String == "turn_completed" {
                    outcome = Self.outcome(update["stop_reason"] as? String)
                }
            }
        }
    }

    static func outcome(_ reason: String?) -> RunOutcome {
        switch reason {
        case "end_turn", "max_tokens", "max_turn_requests", "refusal": return .succeeded
        case "cancelled": return .cancelled
        default: return .failed(exitCode: 1)
        }
    }
}

import Foundation

extension Scheduler {
    /// Socket requests stage attachments off the main actor, then recheck the session before sending.
    public func controlRequest(_ method: String, _ params: [String: Any]) async -> Result<Any, ControlError> {
        guard method == ControlMethod.sessionsMessage.rawValue, params["attachments"] != nil else {
            return control(method, params)
        }
        do {
            return .success(try await sendAttachments(params))
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(ControlError(error.localizedDescription))
        }
    }

    private func sendAttachments(_ params: [String: Any]) async throws -> Any {
        let record = try session(params)
        let paths = try value(params, "attachments", as: [String].self)
        let text = try value(params, "text", as: String.self)
        guard !paths.isEmpty else { return try control(ControlMethod.sessionsMessage.rawValue, params).get() }
        guard canMessage(record), !record.hasBlockingQuestion else {
            throw ControlError("That session cannot take a message now. Answer the blocking question first.")
        }
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ControlError("Attachments need absolute file paths.")
        }
        let store = try history.attachments(for: record)
        let attachments = try await Task.detached {
            try store.stage(paths.map { URL(fileURLWithPath: $0) })
        }.value
        do {
            var message = params
            // Pin the selected session across the suspension, even if a newer run appeared meanwhile.
            message["session"] = record.id.uuidString
            message["attachments"] = nil
            message["text"] = try ChatMessage(text: text, attachments: attachments).encoded()
            return try control(ControlMethod.sessionsMessage.rawValue, message).get()
        } catch {
            await Task.detached {
                for attachment in attachments { try? store.discard(attachment) }
            }.value
            throw error
        }
    }
}

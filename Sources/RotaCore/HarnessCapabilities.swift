import Foundation

/// The contract belongs to the execution mode: Claude's two hosts have different capabilities.
public struct HarnessCapabilities: Equatable, Sendable {
    public enum Messages: String, Sendable { case steer, queued, terminal }
    public enum Questions: String, Sendable { case hosted, hooks, laterMessage, unavailable }
    public enum Images: String, Sendable { case blocks, localPath, fileReferences }
    public let messages: Messages
    public let questions: Questions
    public let images: Images
    public let streamsText: Bool
    public let exposesReasoning: Bool
    public let waitsForBackgroundWork: Bool
}

extension LaunchMode {
    public var name: String {
        switch self {
        case .claudeStream: return "claudeStream"
        case .claudeInteractive: return "claudeInteractive"
        case .codexDaemon: return "codexDaemon"
        case .grokACP: return "grokACP"
        case .antigravityStream: return "antigravityStream"
        case .screen: return "screen"
        case .terminal(let harness): return "terminal/" + harness.rawValue
        }
    }

    public var capabilities: HarnessCapabilities {
        switch self {
        case .claudeStream:
            return .init(messages: .steer, questions: .hooks, images: .blocks,
                         streamsText: true, exposesReasoning: true, waitsForBackgroundWork: true)
        case .claudeInteractive:
            return .init(messages: .steer, questions: .hooks, images: .fileReferences,
                         streamsText: false, exposesReasoning: true, waitsForBackgroundWork: true)
        case .codexDaemon:
            return .init(messages: .steer, questions: .hosted, images: .localPath,
                         streamsText: true, exposesReasoning: true, waitsForBackgroundWork: false)
        case .grokACP:
            return .init(messages: .queued, questions: .hosted, images: .blocks,
                         streamsText: true, exposesReasoning: true, waitsForBackgroundWork: true)
        case .antigravityStream:
            return .init(messages: .queued, questions: .laterMessage, images: .fileReferences,
                         streamsText: true, exposesReasoning: true, waitsForBackgroundWork: false)
        case .terminal:
            return .init(messages: .terminal, questions: .unavailable, images: .fileReferences,
                         streamsText: false, exposesReasoning: true, waitsForBackgroundWork: false)
        case .screen:
            return .init(messages: .terminal, questions: .unavailable, images: .fileReferences,
                         streamsText: false, exposesReasoning: false, waitsForBackgroundWork: false)
        }
    }
}

extension RunRecord {
    /// The daemon may outlive an executable upgrade. Never restart a helper hosting somebody else's sessions.
    public var compatibilityNotice: String? {
        guard let cli = cliVersion.flatMap(Self.semanticVersion),
              let server = serverVersion.flatMap(Self.semanticVersion), cli != server else { return nil }
        return "The selected CLI and running agent service use different versions. "
            + "Restart the agent service after its other sessions finish."
    }

    private static func semanticVersion(_ text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }
}

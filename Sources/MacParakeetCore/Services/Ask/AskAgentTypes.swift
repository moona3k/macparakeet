import Foundation

public struct AskAgentRequest: Sendable {
    public let runID: UUID
    public let scopeID: UUID
    public let messages: [ChatMessage]

    public init(runID: UUID, scopeID: UUID, messages: [ChatMessage]) {
        self.runID = runID
        self.scopeID = scopeID
        self.messages = messages
    }
}

public enum AskAgentEvent: Sendable {
    case activity(String)
    case text(String)
}

public protocol AskAgentRunning: Sendable {
    func run(
        request: AskAgentRequest,
        client: any LLMClientProtocol,
        context: LLMExecutionContext,
        tool: @escaping @Sendable (String, String) async throws -> String,
        onEvent: @escaping @Sendable (AskAgentEvent) async -> Void
    ) async throws -> String
}

public enum AskAgentError: Error, LocalizedError {
    case unavailable(String)
    case protocolViolation(String)
    case budgetExceeded(String)
    case failed(String)
    case invalidModelAction
    case unverifiedLocalCompletion

    public var errorDescription: String? {
        switch self {
        case .unverifiedLocalCompletion:
            "The local model did not confirm that generation finished. This answer is incomplete. Choose another provider for Ask."
        case .invalidModelAction:
            "The selected model could not choose a valid Ask action. Try another model or ask again."
        case .unavailable(let message), .protocolViolation(let message),
            .budgetExceeded(let message), .failed(let message):
            message
        }
    }
}

/// Application transport ceilings, not a promise about a provider's model context window.
/// Initial history leaves space for tool evidence without silently dropping earlier messages.
enum AskAgentBudget {
    static let initialBytes = 16_000
    static let requestBytes = 56_000
    static let initialMessageCount = 76

    static func wireMessages(_ messages: [ChatMessage]) -> [[String: String]] {
        messages.map { ["role": $0.role.rawValue, "content": $0.modelContent] }
    }

    static func serializedBytes(_ messages: [[String: String]]) throws -> Int {
        try JSONSerialization.data(withJSONObject: messages, options: [.withoutEscapingSlashes]).count
    }

    static func validateInitial(_ messages: [ChatMessage]) throws {
        guard messages.count <= initialMessageCount,
            try serializedBytes(wireMessages(messages)) <= initialBytes
        else { throw AskWorkspaceError.contextTooLarge }
    }
}

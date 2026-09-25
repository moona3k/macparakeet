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

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .protocolViolation(let message),
            .budgetExceeded(let message), .failed(let message):
            message
        }
    }
}

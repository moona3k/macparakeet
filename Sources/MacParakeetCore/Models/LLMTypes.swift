import Foundation

// MARK: - Chat Message

public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: Role
    public let content: String

    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Chat Completion Options

public struct ChatCompletionOptions: Sendable {
    public let temperature: Double?
    public let maxTokens: Int?

    public init(temperature: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    public static let `default` = ChatCompletionOptions(temperature: 0.7, maxTokens: nil)
}

// MARK: - Chat Completion Response

public struct ChatCompletionResponse: Sendable {
    public let content: String
    public let model: String
    public let usage: TokenUsage?

    public init(content: String, model: String, usage: TokenUsage? = nil) {
        self.content = content
        self.model = model
        self.usage = usage
    }
}

// MARK: - Token Usage

public struct TokenUsage: Sendable {
    public let promptTokens: Int
    public let completionTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

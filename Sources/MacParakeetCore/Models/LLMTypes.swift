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

public struct ChatJSONSchemaProperty: Codable, Sendable, Equatable {
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

public struct ChatJSONSchema: Codable, Sendable, Equatable {
    public let type: String
    public let properties: [String: ChatJSONSchemaProperty]
    public let required: [String]
    public let additionalProperties: Bool

    public init(
        type: String,
        properties: [String: ChatJSONSchemaProperty],
        required: [String],
        additionalProperties: Bool
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
    }
}

public enum ChatResponseFormat: Sendable, Equatable {
    case jsonSchema(name: String, schema: ChatJSONSchema)
}

public struct ChatCompletionOptions: Sendable, Equatable {
    public let temperature: Double?
    public let maxTokens: Int?
    public let responseFormat: ChatResponseFormat?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        responseFormat: ChatResponseFormat? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.responseFormat = responseFormat
    }

    public static let `default` = ChatCompletionOptions(temperature: 0.7, maxTokens: nil)
}

// MARK: - Chat Completion Response

public struct ChatCompletionResponse: Sendable {
    public let content: String
    public let reasoningContent: String?
    public let model: String
    public let usage: TokenUsage?

    public init(
        content: String,
        reasoningContent: String? = nil,
        model: String,
        usage: TokenUsage? = nil
    ) {
        self.content = content
        self.reasoningContent = reasoningContent
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

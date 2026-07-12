import Foundation

// MARK: - Chat Message

public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: Role
    public let content: String
    public let modelPromptOverride: String?

    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public init(role: Role, content: String, modelPromptOverride: String? = nil) {
        self.role = role
        self.content = content
        self.modelPromptOverride = modelPromptOverride
    }

    public var modelContent: String {
        role == .user ? (modelPromptOverride ?? content) : content
    }
}

// MARK: - Chat Completion Options

public struct ChatJSONSchemaProperty: Codable, Sendable, Equatable {
    public let type: String
    public let items: ChatJSONSchemaArrayItem?

    public init(type: String, items: ChatJSONSchemaArrayItem? = nil) {
        self.type = type
        self.items = items
    }
}

public struct ChatJSONSchemaArrayItem: Codable, Sendable, Equatable {
    public let type: String
    public let properties: [String: ChatJSONSchemaProperty]?
    public let required: [String]?
    public let additionalProperties: Bool?

    public init(
        type: String,
        properties: [String: ChatJSONSchemaProperty]? = nil,
        required: [String]? = nil,
        additionalProperties: Bool? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
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

public enum LLMStructuredOutputCapability: Sendable, Equatable {
    case nativeJSONSchema
    case promptEmbeddedJSONSchema
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

public struct LLMGenerationMetrics: Sendable, Equatable, Codable {
    public let tokensPerSecond: Double?
    public let promptTokensPerSecond: Double?
    public let timeToFirstTokenMs: Int?
    public let peakRSSBytes: UInt64?

    public init(
        tokensPerSecond: Double? = nil,
        promptTokensPerSecond: Double? = nil,
        timeToFirstTokenMs: Int? = nil,
        peakRSSBytes: UInt64? = nil
    ) {
        self.tokensPerSecond = tokensPerSecond
        self.promptTokensPerSecond = promptTokensPerSecond
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.peakRSSBytes = peakRSSBytes
    }

    public func withPeakRSS(_ sample: UInt64?) -> LLMGenerationMetrics {
        guard let sample else { return self }
        let peak = peakRSSBytes.map { max($0, sample) } ?? sample
        return LLMGenerationMetrics(
            tokensPerSecond: tokensPerSecond,
            promptTokensPerSecond: promptTokensPerSecond,
            timeToFirstTokenMs: timeToFirstTokenMs,
            peakRSSBytes: peak
        )
    }
}

public struct ChatCompletionResponse: Sendable {
    public let content: String
    public let reasoningContent: String?
    public let finishReason: String?
    public let model: String
    public let usage: TokenUsage?
    public let generationMetrics: LLMGenerationMetrics?

    public init(
        content: String,
        reasoningContent: String? = nil,
        finishReason: String? = nil,
        model: String,
        usage: TokenUsage? = nil,
        generationMetrics: LLMGenerationMetrics? = nil
    ) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.finishReason = finishReason
        self.model = model
        self.usage = usage
        self.generationMetrics = generationMetrics
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

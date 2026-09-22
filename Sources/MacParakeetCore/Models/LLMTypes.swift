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
    public let nullable: Bool

    public init(
        type: String,
        items: ChatJSONSchemaArrayItem? = nil,
        nullable: Bool = false
    ) {
        self.type = type
        self.items = items
        self.nullable = nullable
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent(ChatJSONSchemaArrayItem.self, forKey: .items)

        if let type = try? container.decode(String.self, forKey: .type) {
            self.type = type
            nullable = false
            return
        }

        let types = try container.decode([String].self, forKey: .type)
        guard types.count == 2,
            types.contains("null"),
            let type = types.first(where: { $0 != "null" })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected one JSON schema type and null"
            )
        }
        self.type = type
        nullable = true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if nullable {
            try container.encode([type, "null"], forKey: .type)
        } else {
            try container.encode(type, forKey: .type)
        }
        try container.encodeIfPresent(items, forKey: .items)
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
    public let topP: Double?
    public let topK: Int?
    public let maxTokens: Int?
    public let thinkingMode: PromptInferenceSettings.ThinkingMode
    public let reasoningEffort: PromptInferenceSettings.ReasoningEffort?
    /// Resolver-owned provenance; directly initialized options have no receipt.
    public let usesPromptInferenceSettings: Bool
    public let effectiveInferenceSettings: PromptInferenceSettings?
    public let responseFormat: ChatResponseFormat?
    /// Opaque thread identity for provider request headers, never part of the JSON body.
    /// Nil identifies a one-shot operation; the HTTP adapter generates its request ID.
    public let conversationID: UUID?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxTokens: Int? = nil,
        thinkingMode: PromptInferenceSettings.ThinkingMode = .providerDefault,
        reasoningEffort: PromptInferenceSettings.ReasoningEffort? = nil,
        responseFormat: ChatResponseFormat? = nil,
        conversationID: UUID? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
        self.usesPromptInferenceSettings = false
        self.effectiveInferenceSettings = nil
        self.responseFormat = responseFormat
        self.conversationID = conversationID
    }

    private init(
        _ options: ChatCompletionOptions,
        usesPromptInferenceSettings: Bool,
        effectiveInferenceSettings: PromptInferenceSettings?
    ) {
        self.temperature = options.temperature
        self.topP = options.topP
        self.topK = options.topK
        self.maxTokens = options.maxTokens
        self.thinkingMode = options.thinkingMode
        self.reasoningEffort = options.reasoningEffort
        self.usesPromptInferenceSettings = usesPromptInferenceSettings
        self.effectiveInferenceSettings = effectiveInferenceSettings
        self.responseFormat = options.responseFormat
        self.conversationID = options.conversationID
    }

    public static let `default` = ChatCompletionOptions(temperature: 0.7, maxTokens: nil)


    /// Attach provenance only after provider filtering has resolved the request.
    func withInferenceReceipt(
        usesPromptInferenceSettings: Bool,
        effectiveSettings: PromptInferenceSettings?
    ) -> ChatCompletionOptions {
        ChatCompletionOptions(
            self,
            usesPromptInferenceSettings: usesPromptInferenceSettings,
            effectiveInferenceSettings: effectiveSettings
        )
    }

    /// Validate numeric input before dispatch, including direct client calls.
    /// Anthropic's narrower range applies only when temperature will be sent:
    /// Top P precedence and the model allow-list remain authoritative.
    func validateInferenceSettings(for config: LLMProviderConfig) throws {
        _ = try PromptInferenceSettings(
            temperature: temperature,
            topP: topP,
            topK: topK,
            maxTokens: maxTokens
        ).validated()
        if config.id == .anthropic,
            AnthropicModelPolicy.acceptsSampling(model: config.modelName),
            topP == nil,
            let temperature,
            temperature > 1
        {
            throw PromptInferenceSettings.ValidationError.outOfRange(
                field: .temperature, minimum: 0, maximum: 1
            )
        }
    }
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
    public let effectiveInferenceSettings: PromptInferenceSettings?

    public init(
        content: String,
        reasoningContent: String? = nil,
        finishReason: String? = nil,
        model: String,
        usage: TokenUsage? = nil,
        generationMetrics: LLMGenerationMetrics? = nil,
        effectiveInferenceSettings: PromptInferenceSettings? = nil
    ) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.finishReason = finishReason
        self.model = model
        self.usage = usage
        self.generationMetrics = generationMetrics
        self.effectiveInferenceSettings = effectiveInferenceSettings
    }
}

// MARK: - Detailed Streaming

/// Provider-owned metadata emitted only after a streaming response has
/// completed successfully.
public struct LLMStreamTerminal: Sendable, Equatable {
    public let provider: String
    public let model: String
    public let usage: LLMUsage?
    public let stopReason: String?
    public let effectiveSettings: PromptInferenceSettings?

    public init(
        provider: String,
        model: String,
        usage: LLMUsage? = nil,
        stopReason: String? = nil,
        effectiveSettings: PromptInferenceSettings? = nil
    ) {
        self.provider = provider
        self.model = model
        self.usage = usage
        self.stopReason = stopReason
        self.effectiveSettings = effectiveSettings
    }

}

/// A detailed completion stream contains zero or more text events followed by
/// exactly one successful terminal event. Failed and cancelled streams do not
/// emit a terminal event.
public enum LLMStreamEvent: Sendable, Equatable {
    case text(String)
    case completed(LLMStreamTerminal)
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

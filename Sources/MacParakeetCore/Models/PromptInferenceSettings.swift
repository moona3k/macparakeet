import Foundation

public struct PromptInferenceSettings: Codable, Sendable, Equatable {
    public enum ThinkingMode: String, Codable, Sendable, CaseIterable {
        case providerDefault
        case enabled
        case disabled
    }

    public enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
        case low
        case medium
        case high
        case xhigh
    }

    public enum Field: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
        case temperature
        case topP
        case topK
        case maxTokens
        case thinkingMode
        case reasoningEffort

        public static func < (lhs: Field, rhs: Field) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case outOfRange(field: Field, minimum: Double, maximum: Double)
        case nonFinite(field: Field)
    }

    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var maxTokens: Int?
    public var thinkingMode: ThinkingMode
    public var reasoningEffort: ReasoningEffort?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxTokens: Int? = nil,
        thinkingMode: ThinkingMode = .providerDefault,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, maxTokens, thinkingMode, reasoningEffort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        topK = try container.decodeIfPresent(Int.self, forKey: .topK)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        thinkingMode =
            try container.decodeIfPresent(ThinkingMode.self, forKey: .thinkingMode)
            ?? .providerDefault
        reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
    }

    public var isDefault: Bool {
        temperature == nil
            && topP == nil
            && topK == nil
            && maxTokens == nil
            && thinkingMode == .providerDefault
            && reasoningEffort == nil
    }

    public var normalized: PromptInferenceSettings? {
        var settings = self
        if settings.thinkingMode != .enabled {
            settings.reasoningEffort = nil
        }
        return settings.isDefault ? nil : settings
    }

    public func validated() throws -> PromptInferenceSettings? {
        if let temperature {
            guard temperature.isFinite else {
                throw ValidationError.nonFinite(field: .temperature)
            }
            guard (0...2).contains(temperature) else {
                throw ValidationError.outOfRange(field: .temperature, minimum: 0, maximum: 2)
            }
        }
        if let topP {
            guard topP.isFinite else {
                throw ValidationError.nonFinite(field: .topP)
            }
            guard (0...1).contains(topP) else {
                throw ValidationError.outOfRange(field: .topP, minimum: 0, maximum: 1)
            }
        }
        if let topK, !(0...1000).contains(topK) {
            throw ValidationError.outOfRange(field: .topK, minimum: 0, maximum: 1000)
        }
        if let maxTokens, !(1...131_072).contains(maxTokens) {
            throw ValidationError.outOfRange(field: .maxTokens, minimum: 1, maximum: 131_072)
        }
        return normalized
    }
}

public struct PromptInferenceResolution: Sendable, Equatable {
    public let options: ChatCompletionOptions
    public let effectiveSettings: PromptInferenceSettings?
    public let unsupportedSettings: Set<PromptInferenceSettings.Field>

    public init(
        options: ChatCompletionOptions,
        effectiveSettings: PromptInferenceSettings?,
        unsupportedSettings: Set<PromptInferenceSettings.Field>
    ) {
        self.options = options
        self.effectiveSettings = effectiveSettings
        self.unsupportedSettings = unsupportedSettings
    }
}

public enum PromptInferenceCapabilityResolver {
    public static func resolve(
        config: LLMProviderConfig,
        baseline: ChatCompletionOptions = .default,
        requested: PromptInferenceSettings?
    ) -> PromptInferenceResolution {
        let requested = requested?.normalized
        var supported = supportedFields(for: config)

        var resolvedOptions = legacyBaseline(config: config, baseline: baseline).applying(requested)
        // Anthropic accepts one sampling control at a time. Top P wins over
        // both an explicit temperature and the inherited 0.7 default, so a
        // saved Top P receipt also remains stable when regenerated.
        if config.id == .anthropic, resolvedOptions.topP != nil {
            supported.remove(.temperature)
        }
        let explicitlyConfigured = configuredFields(in: requested)
        let unsupported = explicitlyConfigured.subtracting(supported)
        if config.id == .ollama, requested?.thinkingMode ?? .providerDefault == .providerDefault {
            resolvedOptions = ChatCompletionOptions(
                temperature: resolvedOptions.temperature,
                topP: resolvedOptions.topP,
                topK: resolvedOptions.topK,
                maxTokens: resolvedOptions.maxTokens,
                thinkingMode: .disabled,
                reasoningEffort: nil,
                responseFormat: resolvedOptions.responseFormat,
                conversationID: resolvedOptions.conversationID
            )
        }

        let filteredOptions = filteredOptions(resolvedOptions, supported: supported)
        let effectiveSettings = effectiveSettings(for: config, options: filteredOptions)
        let usesPromptInferenceSettings = requested != nil

        return PromptInferenceResolution(
            options: filteredOptions.withInferenceReceipt(
                usesPromptInferenceSettings: usesPromptInferenceSettings,
                effectiveSettings: effectiveSettings
            ),
            effectiveSettings: effectiveSettings,
            unsupportedSettings: unsupported
        )
    }

    public static func supportedFields(
        for config: LLMProviderConfig
    ) -> Set<PromptInferenceSettings.Field> {
        switch config.id {
        case .openai:
            var fields: Set<PromptInferenceSettings.Field> = [.maxTokens]
            if !OpenAIModelPolicy.shouldOmitSampling(model: config.modelName) {
                fields.formUnion([.temperature, .topP])
            }
            return fields
        case .anthropic:
            var fields: Set<PromptInferenceSettings.Field> = [.maxTokens]
            if AnthropicModelPolicy.acceptsSampling(model: config.modelName) {
                fields.formUnion([.temperature, .topP])
            }
            return fields
        case .ollama:
            return [.temperature, .topP, .topK, .maxTokens, .thinkingMode]
        case .openaiCompatible:
            return [.temperature, .topP, .topK, .maxTokens, .thinkingMode, .reasoningEffort]
        case .gemini, .openrouter, .lmstudio:
            return [.temperature, .maxTokens]
        case .localCLI:
            return []
        case .inProcessLocal:
            return [.temperature, .maxTokens]
        }
    }

    private static func configuredFields(
        in settings: PromptInferenceSettings?
    ) -> Set<PromptInferenceSettings.Field> {
        guard let settings else { return [] }
        var fields: Set<PromptInferenceSettings.Field> = []
        if settings.temperature != nil { fields.insert(.temperature) }
        if settings.topP != nil { fields.insert(.topP) }
        if settings.topK != nil { fields.insert(.topK) }
        if settings.maxTokens != nil { fields.insert(.maxTokens) }
        if settings.thinkingMode != .providerDefault { fields.insert(.thinkingMode) }
        if settings.reasoningEffort != nil { fields.insert(.reasoningEffort) }
        return fields
    }

    private static func filteredOptions(
        _ options: ChatCompletionOptions,
        supported: Set<PromptInferenceSettings.Field>
    ) -> ChatCompletionOptions {
        ChatCompletionOptions(
            temperature: supported.contains(.temperature) ? options.temperature : nil,
            topP: supported.contains(.topP) ? options.topP : nil,
            topK: supported.contains(.topK) ? options.topK : nil,
            maxTokens: supported.contains(.maxTokens) ? options.maxTokens : nil,
            thinkingMode: supported.contains(.thinkingMode) ? options.thinkingMode : .providerDefault,
            reasoningEffort: supported.contains(.reasoningEffort) ? options.reasoningEffort : nil,
            responseFormat: options.responseFormat,
            conversationID: options.conversationID
        )
    }

    private static func legacyBaseline(
        config: LLMProviderConfig,
        baseline: ChatCompletionOptions
    ) -> ChatCompletionOptions {
        guard config.id == .ollama else { return baseline }
        return ChatCompletionOptions(
            thinkingMode: .disabled,
            responseFormat: baseline.responseFormat,
            conversationID: baseline.conversationID
        )
    }

    private static func effectiveSettings(
        for config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> PromptInferenceSettings? {
        PromptInferenceSettings(
            temperature: options.temperature,
            topP: options.topP,
            topK: options.topK,
            maxTokens: config.id == .anthropic ? (options.maxTokens ?? 4096) : options.maxTokens,
            thinkingMode: options.thinkingMode,
            reasoningEffort: options.reasoningEffort
        ).normalized
    }
}

enum OpenAIModelPolicy {
    static func shouldOmitSampling(model: String) -> Bool {
        let lowered = model.lowercased()
        if isReasoningModel(lowered) { return true }
        if lowered.contains("chat") { return false }
        guard lowered.hasPrefix("gpt-") else { return false }
        let digits = lowered.dropFirst(4).prefix(while: { $0.isNumber })
        return (Int(digits) ?? 0) >= 5
    }

    private static func isReasoningModel(_ model: String) -> Bool {
        guard model.hasPrefix("o") else { return false }
        let suffix = model.dropFirst()
        guard let generation = suffix.first, generation.isNumber else { return false }
        let prefix = "o\(generation)"
        let boundary = model.dropFirst(prefix.count).first
        return model.hasPrefix(prefix) && (boundary == nil || boundary == "-")
    }
}

enum AnthropicModelPolicy {
    private static let samplingCompatibleModelIDs: Set<String> = [
        "claude-2", "claude-2.0", "claude-2.1",
        "claude-instant", "claude-instant-1", "claude-instant-1.0",
        "claude-instant-1.1", "claude-instant-1.2",
        "claude-3-opus-20240229", "claude-3-sonnet-20240229",
        "claude-3-haiku-20240307", "claude-3-5-sonnet-20240620",
        "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022",
        "claude-3-7-sonnet-20250219",
        "claude-opus-4-0", "claude-opus-4-20250514",
        "claude-opus-4-1", "claude-opus-4-1-20250805",
        "claude-opus-4-5", "claude-opus-4-5-20251101", "claude-opus-4-6",
        "claude-sonnet-4-0", "claude-sonnet-4-20250514",
        "claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-sonnet-4-6",
        "claude-haiku-4-5", "claude-haiku-4-5-20251001",
    ]

    static func acceptsSampling(model: String) -> Bool {
        samplingCompatibleModelIDs.contains(model.lowercased())
    }
}

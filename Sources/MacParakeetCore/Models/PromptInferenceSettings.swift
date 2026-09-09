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

    public enum ValidationError: LocalizedError, Sendable, Equatable {
        case outOfRange(field: Field, minimum: Double, maximum: Double)
        case nonFinite(field: Field)
        case unsupportedPromptCategory

        public var errorDescription: String? {
            switch self {
            case .outOfRange(let field, let minimum, let maximum):
                return "\(field.rawValue) must be from \(minimum.formatted()) to \(maximum.formatted())."
            case .nonFinite(let field):
                return "\(field.rawValue) must be a finite number."
            case .unsupportedPromptCategory:
                return "Generation settings are only supported for result prompts."
            }
        }
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
        self = try validated() ?? Self()
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

/// Presentation-only information for a prompt's effective provider and model.
/// It intentionally preserves requested values even when dispatch validation
/// would reject them, so callers can explain and remove an incompatible draft.
public struct PromptInferencePresentation: Sendable, Equatable {
    public enum ModelOverrideStatus: Sendable, Equatable {
        case inherited
        case applied
        case invalid(reason: String)
    }

    public let provider: LLMProviderID
    public let configuredModel: String
    public let requestedModelOverride: String?
    /// Nil when the requested override is locally incompatible.
    public let effectiveModel: String?
    public let modelOverrideStatus: ModelOverrideStatus
    /// The caller's unmodified settings, including values that are currently unavailable.
    public let requestedSettings: PromptInferenceSettings?
    /// The settings that would be sent after resolver filtering, when valid.
    public let effectiveSettings: PromptInferenceSettings?
    /// Dispatch validation failure for `requestedSettings`, without dropping it.
    public let validationError: PromptInferenceSettings.ValidationError?
    public let fieldCapabilities: [PromptInferenceSettings.Field: PromptInferenceFieldCapability]

    public init(
        provider: LLMProviderID,
        configuredModel: String,
        requestedModelOverride: String?,
        effectiveModel: String?,
        modelOverrideStatus: ModelOverrideStatus,
        requestedSettings: PromptInferenceSettings?,
        effectiveSettings: PromptInferenceSettings?,
        validationError: PromptInferenceSettings.ValidationError?,
        fieldCapabilities: [PromptInferenceSettings.Field: PromptInferenceFieldCapability]
    ) {
        self.provider = provider
        self.configuredModel = configuredModel
        self.requestedModelOverride = requestedModelOverride
        self.effectiveModel = effectiveModel
        self.modelOverrideStatus = modelOverrideStatus
        self.requestedSettings = requestedSettings
        self.effectiveSettings = effectiveSettings
        self.validationError = validationError
        self.fieldCapabilities = fieldCapabilities
    }
}

public struct PromptInferenceFieldCapability: Sendable, Equatable {
    public enum Availability: String, Sendable, Equatable {
        /// The current adapter has a documented request mapping for this field.
        case supported
        /// The current adapter does not send this field for the effective provider/model.
        case unsupported
        /// Explicit values are serialized, but endpoint or model acceptance is not known.
        case unverified
    }

    public enum DefaultSource: String, Sendable, Equatable {
        /// The application supplies a value when this field is left automatic.
        case application
        /// The application omits the field and lets the provider choose its default.
        case provider
        /// The integration cannot identify the automatic value's source.
        case unknown
        case notApplicable
    }

    /// A provider-documented range. Application validation bounds are never
    /// represented here as a model limit.
    public struct KnownRange: Sendable, Equatable {
        public let minimum: Double
        public let maximum: Double

        public init(minimum: Double, maximum: Double) {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    public let availability: Availability
    public let allowedThinkingModes: [PromptInferenceSettings.ThinkingMode]
    public let allowedReasoningEfforts: [PromptInferenceSettings.ReasoningEffort]
    public let knownRange: KnownRange?
    public let defaultSource: DefaultSource
    public let reason: String?
    public let isDiscouraged: Bool

    public init(
        availability: Availability,
        allowedThinkingModes: [PromptInferenceSettings.ThinkingMode] = [],
        allowedReasoningEfforts: [PromptInferenceSettings.ReasoningEffort] = [],
        knownRange: KnownRange? = nil,
        defaultSource: DefaultSource,
        reason: String? = nil,
        isDiscouraged: Bool = false
    ) {
        self.availability = availability
        self.allowedThinkingModes = allowedThinkingModes
        self.allowedReasoningEfforts = allowedReasoningEfforts
        self.knownRange = knownRange
        self.defaultSource = defaultSource
        self.reason = reason
        self.isDiscouraged = isDiscouraged
    }
}

public enum PromptInferenceCapabilityResolver {
    /// Returns editor and compatibility metadata without validating away a
    /// saved draft. `resolve` remains the sole dispatch-validation path.
    public static func presentation(
        config: LLMProviderConfig,
        modelOverride: String?,
        baseline: ChatCompletionOptions = .default,
        requested: PromptInferenceSettings?
    ) -> PromptInferencePresentation {
        let overrideResolution = config.resolvingModelOverride(modelOverride)
        let effectiveConfig: LLMProviderConfig
        let modelOverrideStatus: PromptInferencePresentation.ModelOverrideStatus
        let effectiveModel: String?

        switch overrideResolution {
        case .resolved(let resolvedConfig):
            effectiveConfig = resolvedConfig
            effectiveModel = resolvedConfig.modelName
            modelOverrideStatus = modelOverride == nil ? .inherited : .applied
        case .invalid(_, let reason):
            effectiveConfig = config
            effectiveModel = nil
            modelOverrideStatus = .invalid(reason: reason)
        }

        let effectiveSettings: PromptInferenceSettings?
        let validationError: PromptInferenceSettings.ValidationError?
        switch overrideResolution {
        case .invalid:
            effectiveSettings = nil
            validationError = nil
        case .resolved:
            do {
                effectiveSettings = try resolve(
                    config: effectiveConfig,
                    baseline: baseline,
                    requested: requested
                ).effectiveSettings
                validationError = nil
            } catch let error as PromptInferenceSettings.ValidationError {
                effectiveSettings = nil
                validationError = error
            } catch {
                effectiveSettings = nil
                validationError = nil
            }
        }

        return PromptInferencePresentation(
            provider: config.id,
            configuredModel: config.modelName,
            requestedModelOverride: modelOverride,
            effectiveModel: effectiveModel,
            modelOverrideStatus: modelOverrideStatus,
            requestedSettings: requested,
            effectiveSettings: effectiveSettings,
            validationError: validationError,
            fieldCapabilities: fieldCapabilities(for: effectiveConfig, baseline: baseline)
        )
    }

    public static func resolve(
        config: LLMProviderConfig,
        baseline: ChatCompletionOptions = .default,
        requested: PromptInferenceSettings?
    ) throws -> PromptInferenceResolution {
        let requested = try requested?.validated()
        var supported = supportedFields(for: config)

        var resolvedOptions = legacyBaseline(
            config: config,
            baseline: baseline,
            requested: requested
        ).applying(requested)
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
        try filteredOptions.validateInferenceSettings(for: config)
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
            if OpenAIModelPolicy.requiresMaxCompletionTokens(model: config.modelName) {
                var fields: Set<PromptInferenceSettings.Field> = [.maxTokens]
                if !OpenAIModelPolicy.shouldOmitSampling(model: config.modelName) {
                    fields.formUnion([.temperature, .topP])
                }
                return fields
            }
            return [.temperature, .topP, .topK, .maxTokens, .thinkingMode, .reasoningEffort]
        case .openrouter:
            var fields: Set<PromptInferenceSettings.Field> = [.maxTokens]
            if !OpenAIModelPolicy.shouldOmitSampling(model: config.modelName) {
                fields.insert(.temperature)
            }
            return fields
        case .gemini, .lmstudio:
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

    private static func fieldCapabilities(
        for config: LLMProviderConfig,
        baseline: ChatCompletionOptions
    ) -> [PromptInferenceSettings.Field: PromptInferenceFieldCapability] {
        Dictionary(
            uniqueKeysWithValues: PromptInferenceSettings.Field.allCases.map { field in
                (field, fieldCapability(for: field, config: config, baseline: baseline))
            }
        )
    }

    private static func fieldCapability(
        for field: PromptInferenceSettings.Field,
        config: LLMProviderConfig,
        baseline: ChatCompletionOptions
    ) -> PromptInferenceFieldCapability {
        let supported = supportedFields(for: config).contains(field)
        let availability: PromptInferenceFieldCapability.Availability
        if !supported {
            availability = .unsupported
        } else if config.id == .openaiCompatible || config.id == .openrouter
            || (config.id == .ollama && field == .thinkingMode)
        {
            availability = .unverified
        } else {
            availability = .supported
        }

        let isGemini3Temperature =
            field == .temperature && config.id == .gemini && isGemini3(config.modelName)
        let knownRange: PromptInferenceFieldCapability.KnownRange?
        if field == .temperature,
            config.id == .anthropic,
            AnthropicModelPolicy.acceptsSampling(model: config.modelName)
        {
            knownRange = .init(minimum: 0, maximum: 1)
        } else {
            knownRange = nil
        }

        let allowedThinkingModes: [PromptInferenceSettings.ThinkingMode]
        if field == .thinkingMode && availability != .unsupported,
            config.id == .ollama || config.id == .openaiCompatible
        {
            allowedThinkingModes = PromptInferenceSettings.ThinkingMode.allCases
        } else {
            allowedThinkingModes = []
        }

        let allowedReasoningEfforts: [PromptInferenceSettings.ReasoningEffort]
        if field == .reasoningEffort && availability != .unsupported, config.id == .openaiCompatible {
            allowedReasoningEfforts = PromptInferenceSettings.ReasoningEffort.allCases
        } else {
            allowedReasoningEfforts = []
        }

        let reason: String?
        switch availability {
        case .supported:
            reason = isGemini3Temperature
                ? "Gemini 3 recommends automatic sampling for this setting."
                : nil
        case .unsupported:
            reason = field == .thinkingMode || field == .reasoningEffort
                ? "Not available with this provider or model."
                : "This provider or model does not support this setting."
        case .unverified:
            reason = config.id == .ollama
                ? "Thinking support depends on the selected Ollama model; sent as requested."
                : "Custom endpoint support is unverified; sent as requested."
        }

        return PromptInferenceFieldCapability(
            availability: availability,
            allowedThinkingModes: allowedThinkingModes,
            allowedReasoningEfforts: allowedReasoningEfforts,
            knownRange: knownRange,
            defaultSource: defaultSource(for: field, config: config, baseline: baseline, availability: availability),
            reason: reason,
            isDiscouraged: isGemini3Temperature && availability == .supported
        )
    }

    private static func defaultSource(
        for field: PromptInferenceSettings.Field,
        config: LLMProviderConfig,
        baseline: ChatCompletionOptions,
        availability: PromptInferenceFieldCapability.Availability
    ) -> PromptInferenceFieldCapability.DefaultSource {
        guard availability != .unsupported else { return .notApplicable }
        if field == .maxTokens, config.id == .anthropic { return .application }
        if field == .thinkingMode, config.id == .ollama { return .application }

        let automatic = legacyBaseline(config: config, baseline: baseline, requested: nil)
        let appliesApplicationValue: Bool
        switch field {
        case .temperature: appliesApplicationValue = automatic.temperature != nil
        case .topP: appliesApplicationValue = automatic.topP != nil
        case .topK: appliesApplicationValue = automatic.topK != nil
        case .maxTokens: appliesApplicationValue = automatic.maxTokens != nil
        case .thinkingMode: appliesApplicationValue = automatic.thinkingMode != .providerDefault
        case .reasoningEffort: appliesApplicationValue = automatic.reasoningEffort != nil
        }
        return appliesApplicationValue ? .application : .provider
    }

    private static func legacyBaseline(
        config: LLMProviderConfig,
        baseline: ChatCompletionOptions,
        requested: PromptInferenceSettings?
    ) -> ChatCompletionOptions {
        if config.id == .ollama {
            return ChatCompletionOptions(
                thinkingMode: .disabled,
                responseFormat: baseline.responseFormat,
                conversationID: baseline.conversationID
            )
        }
        // Prompt-generation callers inherit `.default`. Gemini 3 recommends
        // omitting that legacy 0.7 baseline so its provider default applies.
        // An explicit prompt temperature, including a historical 0.7 receipt,
        // is overlaid below and therefore remains an explicit request.
        guard config.id == .gemini,
            isGemini3(config.modelName),
            baseline == .default,
            requested?.temperature == nil
        else {
            return baseline
        }
        return ChatCompletionOptions(
            topP: baseline.topP,
            topK: baseline.topK,
            maxTokens: baseline.maxTokens,
            thinkingMode: baseline.thinkingMode,
            reasoningEffort: baseline.reasoningEffort,
            responseFormat: baseline.responseFormat,
            conversationID: baseline.conversationID
        )
    }

    private static func isGemini3(_ model: String) -> Bool {
        model.lowercased().hasPrefix("gemini-3")
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

// The overlay is an intermediate value, not dispatch-ready options. Only the
// resolver may use it before provider filtering and receipt construction.
private extension ChatCompletionOptions {
    func applying(_ settings: PromptInferenceSettings?) -> ChatCompletionOptions {
        guard let settings else { return self }
        let resolvedThinkingMode =
            settings.thinkingMode == .providerDefault
            ? thinkingMode
            : settings.thinkingMode
        let resolvedReasoningEffort: PromptInferenceSettings.ReasoningEffort?
        if resolvedThinkingMode != .enabled {
            resolvedReasoningEffort = nil
        } else if settings.thinkingMode == .providerDefault {
            resolvedReasoningEffort = reasoningEffort
        } else {
            resolvedReasoningEffort = settings.reasoningEffort
        }
        return ChatCompletionOptions(
            temperature: settings.temperature ?? temperature,
            topP: settings.topP ?? topP,
            topK: settings.topK ?? topK,
            maxTokens: settings.maxTokens ?? maxTokens,
            thinkingMode: resolvedThinkingMode,
            reasoningEffort: resolvedReasoningEffort,
            responseFormat: responseFormat,
            conversationID: conversationID
        )
    }
}

enum OpenAIModelPolicy {
    /// Last path component of a provider-prefixed ID (`openai/gpt-5.6-luna` →
    /// `gpt-5.6-luna`). Gateways such as Vercel AI Gateway and OpenRouter use
    /// this form; native OpenAI IDs are returned unchanged.
    static func canonicalModelID(_ model: String) -> String {
        let lowered = model.lowercased()
        guard let slash = lowered.lastIndex(of: "/") else { return lowered }
        return String(lowered[lowered.index(after: slash)...])
    }

    static func shouldOmitSampling(model: String) -> Bool {
        let id = canonicalModelID(model)
        if isReasoningModel(id) { return true }
        if id.contains("chat") { return false }
        return gptMajorVersion(id).map { $0 >= 5 } ?? false
    }

    static func requiresMaxCompletionTokens(model: String) -> Bool {
        let id = canonicalModelID(model)
        if isReasoningModel(id) { return true }
        return gptMajorVersion(id).map { $0 >= 5 } ?? false
    }

    static func isReasoningModelID(_ model: String) -> Bool {
        isReasoningModel(canonicalModelID(model))
    }

    /// Major version of a "gpt-<n>..." model ID ("gpt-5.5" → 5, "gpt-10" → 10),
    /// or nil for IDs without a gpt- numeric prefix. Accepts gateway prefixes.
    static func gptMajorVersion(_ model: String) -> Int? {
        let id = canonicalModelID(model)
        guard id.hasPrefix("gpt-") else { return nil }
        let digits = id.dropFirst(4).prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private static func isReasoningModel(_ id: String) -> Bool {
        guard id.hasPrefix("o") else { return false }
        let suffix = id.dropFirst()
        guard let generation = suffix.first, generation.isNumber else { return false }
        let prefix = "o\(generation)"
        let boundary = id.dropFirst(prefix.count).first
        return id.hasPrefix(prefix) && (boundary == nil || boundary == "-")
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

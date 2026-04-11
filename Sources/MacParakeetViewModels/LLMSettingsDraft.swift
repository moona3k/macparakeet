import Foundation
import MacParakeetCore

public struct LLMSettingsDraft: Equatable, Sendable {
    public enum ValidationError: LocalizedError, Equatable {
        case missingAPIKey
        case missingModelSelection
        case missingCustomModel
        case invalidBaseURL
        case missingCommandTemplate

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Enter an API key."
            case .missingModelSelection:
                return "Choose a model."
            case .missingCustomModel:
                return "Enter a custom model ID."
            case .invalidBaseURL:
                return "Enter a valid HTTPS base URL, or use localhost for local servers."
            case .missingCommandTemplate:
                return "Enter a CLI command."
            }
        }
    }

    public var providerID: LLMProviderID?
    public var apiKeyInput: String
    public var suggestedModelName: String
    public var useCustomModel: Bool
    public var customModelName: String
    public var baseURLOverride: String

    // Local CLI fields
    public var commandTemplate: String
    public var selectedCLITemplate: LocalCLITemplate?
    public var cliTimeoutSeconds: Double
    public var aiFormatterEnabled: Bool
    public var aiFormatterPrompt: String

    public init(
        providerID: LLMProviderID? = nil,
        apiKeyInput: String = "",
        suggestedModelName: String = "",
        useCustomModel: Bool = false,
        customModelName: String = "",
        baseURLOverride: String = "",
        commandTemplate: String = "",
        selectedCLITemplate: LocalCLITemplate? = nil,
        cliTimeoutSeconds: Double = LocalCLIConfig.defaultTimeout,
        aiFormatterEnabled: Bool = false,
        aiFormatterPrompt: String = AIFormatter.defaultPromptTemplate
    ) {
        self.providerID = providerID
        self.apiKeyInput = apiKeyInput
        self.suggestedModelName = suggestedModelName
        self.useCustomModel = useCustomModel
        self.customModelName = customModelName
        self.baseURLOverride = baseURLOverride
        self.commandTemplate = commandTemplate
        self.selectedCLITemplate = selectedCLITemplate
        self.cliTimeoutSeconds = max(LocalCLIConfig.minimumTimeout, cliTimeoutSeconds)
        self.aiFormatterEnabled = aiFormatterEnabled
        self.aiFormatterPrompt = AIFormatter.normalizedPromptTemplate(aiFormatterPrompt)
    }

    public var requiresAPIKey: Bool {
        providerID?.requiresAPIKey ?? false
    }

    public var trimmedAPIKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedCustomModelName: String {
        customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedBaseURLOverride: String {
        baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var effectiveModelName: String {
        useCustomModel ? trimmedCustomModelName : suggestedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedCommandTemplate: String {
        commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedAIFormatterPrompt: String {
        AIFormatter.normalizedPromptTemplate(aiFormatterPrompt)
    }

    public var validationError: ValidationError? {
        validationError(allowMissingModelName: false)
    }

    private func validationError(allowMissingModelName: Bool) -> ValidationError? {
        guard let providerID else { return nil }
        if providerID == .localCLI {
            return trimmedCommandTemplate.isEmpty ? .missingCommandTemplate : nil
        }
        if requiresAPIKey && trimmedAPIKey.isEmpty {
            return .missingAPIKey
        }
        if useCustomModel {
            if !allowMissingModelName && trimmedCustomModelName.isEmpty {
                return .missingCustomModel
            }
        } else if !allowMissingModelName
                    && suggestedModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingModelSelection
        }
        if !trimmedBaseURLOverride.isEmpty {
            guard let overrideURL = URL(string: trimmedBaseURLOverride),
                  Self.isAllowedBaseURLOverride(overrideURL) else {
                return .invalidBaseURL
            }
        }
        return nil
    }

    public var isValid: Bool {
        validationError == nil
    }

    public func buildConfig(
        defaultBaseURL: String,
        allowMissingModelName: Bool = false
    ) throws -> LLMProviderConfig? {
        guard let providerID else { return nil }
        if let validationError = validationError(allowMissingModelName: allowMissingModelName) {
            throw validationError
        }

        if providerID == .localCLI {
            return .localCLI()
        }

        let baseURL: URL
        if !trimmedBaseURLOverride.isEmpty {
            guard let override = URL(string: trimmedBaseURLOverride) else {
                throw ValidationError.invalidBaseURL
            }
            guard Self.isAllowedBaseURLOverride(override) else {
                throw ValidationError.invalidBaseURL
            }
            baseURL = override
        } else if let defaultURL = URL(string: defaultBaseURL), !defaultBaseURL.isEmpty {
            baseURL = defaultURL
        } else {
            throw ValidationError.invalidBaseURL
        }

        return LLMProviderConfig(
            id: providerID,
            baseURL: baseURL,
            apiKey: trimmedAPIKey.isEmpty ? nil : trimmedAPIKey,
            modelName: effectiveModelName,
            isLocal: providerID.isLocal
        )
    }

    public static func defaults(
        for providerID: LLMProviderID?,
        apiKey: String = "",
        defaultModelName: String = "",
        cliConfig: LocalCLIConfig? = nil,
        aiFormatterEnabled: Bool = false,
        aiFormatterPrompt: String = AIFormatter.defaultPromptTemplate
    ) -> Self {
        let selectedCLITemplate = cliConfig.map { LocalCLITemplate.inferredTemplate(for: $0.commandTemplate) } ?? nil
        return LLMSettingsDraft(
            providerID: providerID,
            apiKeyInput: providerID?.requiresAPIKey == true ? apiKey : "",
            suggestedModelName: defaultModelName,
            useCustomModel: false,
            customModelName: "",
            baseURLOverride: "",
            commandTemplate: cliConfig?.commandTemplate ?? "",
            selectedCLITemplate: selectedCLITemplate,
            cliTimeoutSeconds: cliConfig?.timeoutSeconds ?? LocalCLIConfig.defaultTimeout,
            aiFormatterEnabled: aiFormatterEnabled,
            aiFormatterPrompt: aiFormatterPrompt
        )
    }

    public static func fromStoredConfig(
        _ config: LLMProviderConfig,
        suggestedModels: [String],
        defaultModelName: String,
        defaultBaseURL: String,
        cliConfig: LocalCLIConfig? = nil,
        aiFormatterEnabled: Bool = false,
        aiFormatterPrompt: String = AIFormatter.defaultPromptTemplate
    ) -> Self {
        let isSuggestedModel = suggestedModels.contains(config.modelName)
        let selectedCLITemplate = cliConfig.map { LocalCLITemplate.inferredTemplate(for: $0.commandTemplate) } ?? nil
        return LLMSettingsDraft(
            providerID: config.id,
            apiKeyInput: config.apiKey ?? "",
            suggestedModelName: isSuggestedModel ? config.modelName : defaultModelName,
            useCustomModel: !isSuggestedModel,
            customModelName: isSuggestedModel ? "" : config.modelName,
            baseURLOverride: config.baseURL.absoluteString == defaultBaseURL ? "" : config.baseURL.absoluteString,
            commandTemplate: cliConfig?.commandTemplate ?? "",
            selectedCLITemplate: selectedCLITemplate,
            cliTimeoutSeconds: cliConfig?.timeoutSeconds ?? LocalCLIConfig.defaultTimeout,
            aiFormatterEnabled: aiFormatterEnabled,
            aiFormatterPrompt: aiFormatterPrompt
        )
    }

    private static func isAllowedBaseURLOverride(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" {
            return true
        }
        guard scheme == "http" else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

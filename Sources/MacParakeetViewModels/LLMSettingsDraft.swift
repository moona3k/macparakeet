import Foundation
import MacParakeetCore

public struct LLMSettingsDraft: Equatable, Sendable {
    public enum ValidationError: LocalizedError, Equatable {
        case missingAPIKey
        case missingCustomModel
        case invalidBaseURL

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Enter an API key."
            case .missingCustomModel:
                return "Enter a custom model ID."
            case .invalidBaseURL:
                return "Enter a valid base URL."
            }
        }
    }

    public var providerID: LLMProviderID
    public var apiKeyInput: String
    public var suggestedModelName: String
    public var useCustomModel: Bool
    public var customModelName: String
    public var baseURLOverride: String

    public init(
        providerID: LLMProviderID = .openai,
        apiKeyInput: String = "",
        suggestedModelName: String = "gpt-5.4",
        useCustomModel: Bool = false,
        customModelName: String = "",
        baseURLOverride: String = ""
    ) {
        self.providerID = providerID
        self.apiKeyInput = apiKeyInput
        self.suggestedModelName = suggestedModelName
        self.useCustomModel = useCustomModel
        self.customModelName = customModelName
        self.baseURLOverride = baseURLOverride
    }

    public var requiresAPIKey: Bool {
        !providerID.isLocal
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

    public var validationError: ValidationError? {
        if requiresAPIKey && trimmedAPIKey.isEmpty {
            return .missingAPIKey
        }
        if useCustomModel && trimmedCustomModelName.isEmpty {
            return .missingCustomModel
        }
        if !trimmedBaseURLOverride.isEmpty && URL(string: trimmedBaseURLOverride) == nil {
            return .invalidBaseURL
        }
        return nil
    }

    public var isValid: Bool {
        validationError == nil
    }

    public func buildConfig(defaultBaseURL: String) throws -> LLMProviderConfig {
        if let validationError {
            throw validationError
        }

        let baseURL: URL
        if !trimmedBaseURLOverride.isEmpty {
            guard let override = URL(string: trimmedBaseURLOverride) else {
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
        for providerID: LLMProviderID,
        apiKey: String,
        defaultModelName: String
    ) -> Self {
        LLMSettingsDraft(
            providerID: providerID,
            apiKeyInput: providerID.isLocal ? "" : apiKey,
            suggestedModelName: defaultModelName,
            useCustomModel: false,
            customModelName: "",
            baseURLOverride: ""
        )
    }

    public static func fromStoredConfig(
        _ config: LLMProviderConfig,
        suggestedModels: [String],
        defaultModelName: String,
        defaultBaseURL: String
    ) -> Self {
        let isSuggestedModel = suggestedModels.contains(config.modelName)
        return LLMSettingsDraft(
            providerID: config.id,
            apiKeyInput: config.apiKey ?? "",
            suggestedModelName: isSuggestedModel ? config.modelName : defaultModelName,
            useCustomModel: !isSuggestedModel,
            customModelName: isSuggestedModel ? "" : config.modelName,
            baseURLOverride: config.baseURL.absoluteString == defaultBaseURL ? "" : config.baseURL.absoluteString
        )
    }
}

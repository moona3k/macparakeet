import Foundation
import MacParakeetCore
import Network

public struct LLMSettingsDraft: Equatable, Sendable {
    public enum ValidationError: LocalizedError, Equatable {
        case missingAPIKey
        case missingModelSelection
        case missingCustomModel
        case invalidBaseURL
        case localNetworkHTTPRequiresOptIn
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
                return "Enter a valid base URL. Remote endpoints must use https."
            case .localNetworkHTTPRequiresOptIn:
                return "Turn on local-network HTTP or use https."
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
    public var allowInsecureLocalNetworkHTTP: Bool

    // Local CLI fields
    public var commandTemplate: String
    public var selectedCLITemplate: LocalCLITemplate?
    public var cliTimeoutSeconds: Double
    public var aiFormatterPrompt: String

    public init(
        providerID: LLMProviderID? = nil,
        apiKeyInput: String = "",
        suggestedModelName: String = "",
        useCustomModel: Bool = false,
        customModelName: String = "",
        baseURLOverride: String = "",
        allowInsecureLocalNetworkHTTP: Bool = false,
        commandTemplate: String = "",
        selectedCLITemplate: LocalCLITemplate? = nil,
        cliTimeoutSeconds: Double = LocalCLIConfig.defaultTimeout,
        aiFormatterPrompt: String = AIFormatter.defaultPromptTemplate
    ) {
        self.providerID = providerID
        self.apiKeyInput = apiKeyInput
        self.suggestedModelName = suggestedModelName
        self.useCustomModel = useCustomModel
        self.customModelName = customModelName
        self.baseURLOverride = baseURLOverride
        self.allowInsecureLocalNetworkHTTP = allowInsecureLocalNetworkHTTP
        self.commandTemplate = commandTemplate
        self.selectedCLITemplate = selectedCLITemplate
        self.cliTimeoutSeconds = max(LocalCLIConfig.minimumTimeout, cliTimeoutSeconds)
        self.aiFormatterPrompt = AIFormatter.normalizedPromptTemplate(aiFormatterPrompt)
    }

    public var requiresAPIKey: Bool {
        providerID?.requiresAPIKey ?? false
    }

    public var supportsAPIKey: Bool {
        providerID?.supportsAPIKey ?? false
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
        if providerID.requiresCustomEndpoint && trimmedBaseURLOverride.isEmpty {
            return .invalidBaseURL
        }
        if !trimmedBaseURLOverride.isEmpty {
            guard let overrideURL = URL(string: trimmedBaseURLOverride) else {
                return .invalidBaseURL
            }
            if let validationError = Self.baseURLValidationError(
                overrideURL,
                providerID: providerID,
                allowInsecureLocalNetworkHTTP: allowInsecureLocalNetworkHTTP
            ) {
                return validationError
            }
        }
        return nil
    }

    public var isValid: Bool {
        validationError == nil
    }

    public var isLocalConfiguration: Bool {
        guard let providerID else { return false }
        if providerID == .openaiCompatible,
           let url = URL(string: trimmedBaseURLOverride) {
            return Self.isOpenAICompatibleLocalConfiguration(
                url,
                allowInsecureLocalNetworkHTTP: allowInsecureLocalNetworkHTTP
            )
        }
        return providerID.isLocal
    }

    public var usesInsecureLocalNetworkHTTP: Bool {
        guard providerID == .openaiCompatible,
              allowInsecureLocalNetworkHTTP,
              let url = URL(string: trimmedBaseURLOverride)
        else {
            return false
        }
        return Self.isAllowedInsecureLocalNetworkHTTP(url)
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
            if let validationError = Self.baseURLValidationError(
                override,
                providerID: providerID,
                allowInsecureLocalNetworkHTTP: allowInsecureLocalNetworkHTTP
            ) {
                throw validationError
            }
            baseURL = override
        } else if let defaultURL = URL(string: defaultBaseURL), !defaultBaseURL.isEmpty {
            baseURL = defaultURL
        } else {
            throw ValidationError.invalidBaseURL
        }

        if providerID == .openaiCompatible {
            return .openaiCompatible(
                apiKey: trimmedAPIKey.isEmpty ? nil : trimmedAPIKey,
                model: effectiveModelName,
                baseURL: baseURL,
                isLocal: Self.isOpenAICompatibleLocalConfiguration(
                    baseURL,
                    allowInsecureLocalNetworkHTTP: allowInsecureLocalNetworkHTTP
                )
            )
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
        aiFormatterPrompt: String = AIFormatter.defaultPromptTemplate
    ) -> Self {
        let selectedCLITemplate = cliConfig.map { LocalCLITemplate.inferredTemplate(for: $0.commandTemplate) } ?? nil
        return LLMSettingsDraft(
            providerID: providerID,
            apiKeyInput: providerID?.supportsAPIKey == true ? apiKey : "",
            suggestedModelName: defaultModelName,
            useCustomModel: false,
            customModelName: "",
            baseURLOverride: "",
            allowInsecureLocalNetworkHTTP: false,
            commandTemplate: cliConfig?.commandTemplate ?? "",
            selectedCLITemplate: selectedCLITemplate,
            cliTimeoutSeconds: cliConfig?.timeoutSeconds ?? LocalCLIConfig.defaultTimeout,
            aiFormatterPrompt: aiFormatterPrompt
        )
    }

    public static func fromStoredConfig(
        _ config: LLMProviderConfig,
        suggestedModels: [String],
        defaultModelName: String,
        defaultBaseURL: String,
        cliConfig: LocalCLIConfig? = nil,
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
            allowInsecureLocalNetworkHTTP: Self.shouldRestoreLocalNetworkHTTPOptIn(from: config),
            commandTemplate: cliConfig?.commandTemplate ?? "",
            selectedCLITemplate: selectedCLITemplate,
            cliTimeoutSeconds: cliConfig?.timeoutSeconds ?? LocalCLIConfig.defaultTimeout,
            aiFormatterPrompt: aiFormatterPrompt
        )
    }

    private static func baseURLValidationError(
        _ url: URL,
        providerID: LLMProviderID,
        allowInsecureLocalNetworkHTTP: Bool
    ) -> ValidationError? {
        guard let scheme = url.scheme?.lowercased(),
              url.host != nil else {
            return .invalidBaseURL
        }
        if scheme == "https" {
            return nil
        }
        guard scheme == "http" else {
            return .invalidBaseURL
        }
        // Local providers (Ollama, LM Studio) may be reachable over any host the
        // user configures — LAN IP, mDNS hostname, Tailscale, 0.0.0.0 bind, etc.
        if providerID.isLocal {
            return nil
        }
        if providerID == .openaiCompatible && LLMProviderConfig.isLoopbackEndpoint(url) {
            return nil
        }
        if providerID == .openaiCompatible {
            guard Self.isAllowedInsecureLocalNetworkHTTP(url) else {
                return .invalidBaseURL
            }
            return allowInsecureLocalNetworkHTTP ? nil : .localNetworkHTTPRequiresOptIn
        }
        return .invalidBaseURL
    }

    private static func isOpenAICompatibleLocalConfiguration(
        _ url: URL,
        allowInsecureLocalNetworkHTTP: Bool
    ) -> Bool {
        LLMProviderConfig.isLoopbackEndpoint(url)
            || (allowInsecureLocalNetworkHTTP && isAllowedInsecureLocalNetworkHTTP(url))
    }

    private static func isAllowedInsecureLocalNetworkHTTP(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else {
            return false
        }
        guard !LLMProviderConfig.isLoopbackEndpoint(url) else {
            return false
        }
        guard let host = normalizedHost(from: url) else {
            return false
        }
        return isLocalNetworkHost(host)
    }

    private static func normalizedHost(from url: URL) -> String? {
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        if host.hasSuffix(".local") {
            return true
        }
        if let address = IPv4Address(host) {
            return isLocalNetworkIPv4(Array(address.rawValue))
        }
        if let address = IPv6Address(ipv6HostWithoutScope(host)) {
            return isLocalNetworkIPv6(Array(address.rawValue))
        }
        return false
    }

    private static func ipv6HostWithoutScope(_ host: String) -> String {
        host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? host
    }

    private static func isLocalNetworkIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
            || (first == 100 && (64...127).contains(second))
    }

    private static func isLocalNetworkIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        return (bytes[0] & 0xFE) == 0xFC
            || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80)
    }

    private static func shouldRestoreLocalNetworkHTTPOptIn(from config: LLMProviderConfig) -> Bool {
        config.id == .openaiCompatible
            && config.isLocal
            && isAllowedInsecureLocalNetworkHTTP(config.baseURL)
    }
}

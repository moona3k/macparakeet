import Foundation

// MARK: - Provider Descriptor

public struct LLMProviderDescriptor: Sendable, Equatable {
    public enum ModelListEndpoint: Sendable, Equatable {
        case none
        case openAICompatible
        case anthropic
        case gemini
        case ollama
    }

    public let id: LLMProviderID
    public let displayName: String
    public let defaultBaseURL: String
    public let isLocal: Bool
    public let supportsAPIKey: Bool
    public let requiresAPIKey: Bool
    public let requiresCustomEndpoint: Bool
    public let modelListEndpoint: ModelListEndpoint
    public let defaultModelName: String
    public let fallbackModels: [String]

    public var supportsModelListing: Bool {
        modelListEndpoint != .none
    }

}

// MARK: - Provider ID

public enum LLMProviderID: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case openaiCompatible
    case gemini
    case openrouter
    case ollama
    case lmstudio
    case localCLI

    public var descriptor: LLMProviderDescriptor {
        switch self {
        case .anthropic:
            return LLMProviderDescriptor(
                id: self,
                displayName: "Anthropic",
                defaultBaseURL: "https://api.anthropic.com/v1",
                isLocal: false,
                supportsAPIKey: true,
                requiresAPIKey: true,
                requiresCustomEndpoint: false,
                modelListEndpoint: .anthropic,
                defaultModelName: "claude-sonnet-4-6",
                fallbackModels: [
                    "claude-sonnet-4-6",
                    "claude-opus-4-7",
                    "claude-haiku-4-5",
                ]
            )
        case .openai:
            return LLMProviderDescriptor(
                id: self,
                displayName: "OpenAI",
                defaultBaseURL: "https://api.openai.com/v1",
                isLocal: false,
                supportsAPIKey: true,
                requiresAPIKey: true,
                requiresCustomEndpoint: false,
                modelListEndpoint: .openAICompatible,
                defaultModelName: "gpt-5.5",
                fallbackModels: [
                    "gpt-5.5",
                    "gpt-5.4",
                    "gpt-5.4-mini",
                    "gpt-5.4-nano",
                    "gpt-5.3-chat-latest",
                    "gpt-4.1",
                    "gpt-4.1-mini",
                ]
            )
        case .openaiCompatible:
            return LLMProviderDescriptor(
                id: self,
                displayName: "OpenAI-Compatible",
                defaultBaseURL: "",
                isLocal: false,
                supportsAPIKey: true,
                requiresAPIKey: false,
                requiresCustomEndpoint: true,
                modelListEndpoint: .openAICompatible,
                defaultModelName: "",
                fallbackModels: []
            )
        case .gemini:
            return LLMProviderDescriptor(
                id: self,
                displayName: "Google Gemini",
                defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                isLocal: false,
                supportsAPIKey: true,
                requiresAPIKey: true,
                requiresCustomEndpoint: false,
                modelListEndpoint: .gemini,
                defaultModelName: "gemini-3.5-flash",
                fallbackModels: [
                    "gemini-3.5-flash",
                    "gemini-3.1-pro-preview",
                    "gemini-3.1-flash-lite",
                    "gemini-3-flash-preview",
                    "gemini-3.1-flash-lite-preview",
                    "gemini-2.5-pro",
                    "gemini-2.5-flash",
                ]
            )
        case .openrouter:
            return LLMProviderDescriptor(
                id: self,
                displayName: "OpenRouter",
                defaultBaseURL: "https://openrouter.ai/api/v1",
                isLocal: false,
                supportsAPIKey: true,
                requiresAPIKey: true,
                requiresCustomEndpoint: false,
                modelListEndpoint: .openAICompatible,
                defaultModelName: "anthropic/claude-sonnet-4.6",
                fallbackModels: [
                    "anthropic/claude-sonnet-4.6",
                    "anthropic/claude-opus-4.7",
                    "anthropic/claude-haiku-4-5",
                    "openai/gpt-5.5",
                    "openai/gpt-5.5-pro",
                    "openai/gpt-5.4",
                    "openai/gpt-5.4-pro",
                    "openai/gpt-5.4-mini",
                    "google/gemini-3.5-flash",
                    "google/gemini-3.1-pro-preview",
                    "google/gemini-3.1-flash-lite",
                    "google/gemini-3-flash-preview",
                    "deepseek/deepseek-v4-pro",
                    "deepseek/deepseek-v4-flash",
                    "x-ai/grok-4.3",
                    "mistralai/mistral-medium-3-5",
                    "qwen/qwen3.7-max",
                    "moonshotai/kimi-k2.6",
                    "z-ai/glm-5.1",
                    "perplexity/sonar-pro-search",
                    "meta-llama/llama-4-maverick",
                    "meta-llama/llama-4-scout",
                    "cohere/command-a",
                    "minimax/minimax-m2.7",
                ]
            )
        case .ollama:
            return LLMProviderDescriptor(
                id: self,
                displayName: "Ollama",
                defaultBaseURL: "http://localhost:11434/v1",
                isLocal: true,
                supportsAPIKey: false,
                requiresAPIKey: false,
                requiresCustomEndpoint: false,
                modelListEndpoint: .ollama,
                defaultModelName: "qwen3.5:4b",
                fallbackModels: [
                    "qwen3.5:4b",
                    "qwen3.5:9b",
                    "llama4:8b",
                    "gemma3:4b",
                    "deepseek-v3.2",
                    "qwen3:8b",
                    "mistral",
                ]
            )
        case .lmstudio:
            return LLMProviderDescriptor(
                id: self,
                displayName: "LM Studio",
                defaultBaseURL: "http://localhost:1234/v1",
                isLocal: true,
                supportsAPIKey: true,
                requiresAPIKey: false,
                requiresCustomEndpoint: false,
                modelListEndpoint: .openAICompatible,
                defaultModelName: "",
                fallbackModels: []
            )
        case .localCLI:
            return LLMProviderDescriptor(
                id: self,
                displayName: "Local CLI",
                defaultBaseURL: "http://localhost",
                isLocal: false,
                supportsAPIKey: false,
                requiresAPIKey: false,
                requiresCustomEndpoint: false,
                modelListEndpoint: .none,
                defaultModelName: "",
                fallbackModels: []
            )
        }
    }

    public var displayName: String {
        descriptor.displayName
    }

    /// Whether the provider runs inference on-device (affects context budget).
    /// Local CLI tools typically forward to cloud APIs, so this is `false`.
    public var isLocal: Bool {
        descriptor.isLocal
    }

    /// Whether the provider supports API-key-based auth.
    public var supportsAPIKey: Bool {
        descriptor.supportsAPIKey
    }

    /// Whether the provider needs an API key to function.
    public var requiresAPIKey: Bool {
        descriptor.requiresAPIKey
    }

    /// Whether the provider must be configured with a user-supplied endpoint.
    public var requiresCustomEndpoint: Bool {
        descriptor.requiresCustomEndpoint
    }

    public var defaultBaseURL: String {
        descriptor.defaultBaseURL
    }

    public var modelListEndpoint: LLMProviderDescriptor.ModelListEndpoint {
        descriptor.modelListEndpoint
    }

    public var supportsModelListing: Bool {
        descriptor.supportsModelListing
    }

    public var fallbackModels: [String] {
        descriptor.fallbackModels
    }

    public var defaultModelName: String {
        descriptor.defaultModelName
    }

}

// MARK: - Provider Configuration

public struct LLMProviderConfig: Codable, Sendable, Equatable {
    public let id: LLMProviderID
    public let baseURL: URL
    public let apiKey: String?
    public let modelName: String
    public let isLocal: Bool

    // Exclude apiKey from Codable to prevent leaking to UserDefaults
    private enum CodingKeys: String, CodingKey {
        case id, baseURL, modelName, isLocal
    }

    public init(id: LLMProviderID, baseURL: URL, apiKey: String?, modelName: String, isLocal: Bool) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.isLocal = isLocal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LLMProviderID.self, forKey: .id)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        modelName = try container.decode(String.self, forKey: .modelName)
        isLocal = try container.decode(Bool.self, forKey: .isLocal)
        apiKey = nil // Excluded from Codable — hydrated from Keychain separately
    }

    // MARK: - Factory Methods

    public static func anthropic(
        apiKey: String,
        model: String = LLMProviderID.anthropic.defaultModelName,
        baseURL: URL? = nil
    ) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .anthropic,
            baseURL: baseURL ?? URL(string: LLMProviderID.anthropic.defaultBaseURL)!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func openai(
        apiKey: String,
        model: String = LLMProviderID.openai.defaultModelName,
        baseURL: URL? = nil
    ) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .openai,
            baseURL: baseURL ?? URL(string: LLMProviderID.openai.defaultBaseURL)!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func openaiCompatible(
        apiKey: String? = nil,
        model: String,
        baseURL: URL,
        isLocal: Bool? = nil
    ) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .openaiCompatible,
            baseURL: baseURL,
            apiKey: apiKey,
            modelName: model,
            isLocal: isLocal ?? Self.isLoopbackEndpoint(baseURL)
        )
    }

    public static func gemini(
        apiKey: String,
        model: String = LLMProviderID.gemini.defaultModelName,
        baseURL: URL? = nil
    ) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .gemini,
            baseURL: baseURL ?? URL(string: LLMProviderID.gemini.defaultBaseURL)!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func openrouter(
        apiKey: String,
        model: String = LLMProviderID.openrouter.defaultModelName,
        baseURL: URL? = nil
    ) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .openrouter,
            baseURL: baseURL ?? URL(string: LLMProviderID.openrouter.defaultBaseURL)!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func ollama(
        model: String = LLMProviderID.ollama.defaultModelName,
        baseURL: URL? = nil
    ) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .ollama,
            baseURL: baseURL ?? URL(string: LLMProviderID.ollama.defaultBaseURL)!,
            apiKey: nil,
            modelName: model,
            isLocal: true
        )
    }

    public static func lmstudio(apiKey: String? = nil, model: String = "", baseURL: URL? = nil) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .lmstudio,
            baseURL: baseURL ?? URL(string: LLMProviderID.lmstudio.defaultBaseURL)!,
            apiKey: apiKey,
            modelName: model,
            isLocal: true
        )
    }

    /// Local CLI provider — command and timeout are carried in `LLMExecutionContext`.
    public static func localCLI() -> LLMProviderConfig {
        LLMProviderConfig(
            id: .localCLI,
            baseURL: URL(string: LLMProviderID.localCLI.defaultBaseURL)!,
            apiKey: nil,
            modelName: "cli",
            isLocal: false
        )
    }

    public static func isLoopbackEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

}

import Foundation

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

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .openaiCompatible: return "OpenAI-Compatible"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .localCLI: return "Local CLI"
        }
    }

    /// Whether the provider runs inference on-device (affects context budget).
    /// Local CLI tools typically forward to cloud APIs, so this is `false`.
    public var isLocal: Bool {
        switch self {
        case .ollama, .lmstudio: return true
        case .anthropic, .openai, .openaiCompatible, .gemini, .openrouter, .localCLI: return false
        }
    }

    /// Whether the provider supports API-key-based auth.
    public var supportsAPIKey: Bool {
        switch self {
        case .ollama, .lmstudio, .localCLI: return false
        case .anthropic, .openai, .openaiCompatible, .gemini, .openrouter: return true
        }
    }

    /// Whether the provider needs an API key to function.
    public var requiresAPIKey: Bool {
        switch self {
        case .openaiCompatible, .ollama, .lmstudio, .localCLI: return false
        case .anthropic, .openai, .gemini, .openrouter: return true
        }
    }

    /// Whether the provider must be configured with a user-supplied endpoint.
    public var requiresCustomEndpoint: Bool {
        switch self {
        case .openaiCompatible: return true
        case .anthropic, .openai, .gemini, .openrouter, .ollama, .lmstudio, .localCLI: return false
        }
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

    public static func anthropic(apiKey: String, model: String = "claude-sonnet-4-6", baseURL: URL? = nil) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .anthropic,
            baseURL: baseURL ?? URL(string: "https://api.anthropic.com/v1")!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func openai(apiKey: String, model: String = "gpt-4.1", baseURL: URL? = nil) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .openai,
            baseURL: baseURL ?? URL(string: "https://api.openai.com/v1")!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func openaiCompatible(
        apiKey: String? = nil,
        model: String,
        baseURL: URL
    ) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .openaiCompatible,
            baseURL: baseURL,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func gemini(apiKey: String, model: String = "gemini-2.5-flash", baseURL: URL? = nil) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .gemini,
            baseURL: baseURL ?? URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func openrouter(apiKey: String, model: String = "anthropic/claude-sonnet-4", baseURL: URL? = nil) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .openrouter,
            baseURL: baseURL ?? URL(string: "https://openrouter.ai/api/v1")!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func ollama(model: String = "qwen3.5:4b", baseURL: URL? = nil) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .ollama,
            baseURL: baseURL ?? URL(string: "http://localhost:11434/v1")!,
            apiKey: nil,
            modelName: model,
            isLocal: true
        )
    }

    public static func lmstudio(model: String = "", baseURL: URL? = nil) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .lmstudio,
            baseURL: baseURL ?? URL(string: "http://localhost:1234/v1")!,
            apiKey: nil,
            modelName: model,
            isLocal: true
        )
    }

    /// Local CLI provider — command and timeout are carried in `LLMExecutionContext`.
    public static func localCLI() -> LLMProviderConfig {
        LLMProviderConfig(
            id: .localCLI,
            baseURL: URL(string: "http://localhost")!,
            apiKey: nil,
            modelName: "cli",
            isLocal: false
        )
    }

}

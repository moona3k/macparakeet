import Foundation

// MARK: - Provider ID

public enum LLMProviderID: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case gemini
    case ollama
    case lmstudio
    case custom

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .custom: return "Custom"
        }
    }

    public var isLocal: Bool {
        switch self {
        case .ollama, .lmstudio: return true
        case .anthropic, .openai, .gemini, .custom: return false
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

    public static func anthropic(apiKey: String, model: String = "claude-sonnet-4-20250514") -> LLMProviderConfig {
        LLMProviderConfig(
            id: .anthropic,
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func openai(apiKey: String, model: String = "gpt-4o") -> LLMProviderConfig {
        LLMProviderConfig(
            id: .openai,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func gemini(apiKey: String, model: String = "gemini-2.0-flash") -> LLMProviderConfig {
        LLMProviderConfig(
            id: .gemini,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
            apiKey: apiKey,
            modelName: model,
            isLocal: false
        )
    }

    public static func ollama(model: String = "llama3.2") -> LLMProviderConfig {
        LLMProviderConfig(
            id: .ollama,
            baseURL: URL(string: "http://localhost:11434/v1")!,
            apiKey: nil,
            modelName: model,
            isLocal: true
        )
    }

    public static func lmstudio(model: String, apiKey: String? = nil) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .lmstudio,
            baseURL: URL(string: "http://localhost:1234/v1")!,
            apiKey: apiKey,
            modelName: model,
            isLocal: true
        )
    }

    public static func custom(baseURL: URL, model: String, apiKey: String? = nil, isLocal: Bool = false) -> LLMProviderConfig {
        LLMProviderConfig(
            id: .custom,
            baseURL: baseURL,
            apiKey: apiKey,
            modelName: model,
            isLocal: isLocal
        )
    }
}

import Foundation

public enum LLMError: Error, LocalizedError, Sendable {
    case notConfigured
    case connectionFailed(String)
    case authenticationFailed
    case rateLimited
    case modelNotFound(String)
    case contextTooLong
    case providerError(String)
    case streamingError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No LLM provider configured. Set up a provider in Settings."
        case .connectionFailed(let detail):
            return "Connection failed: \(detail)"
        case .authenticationFailed:
            return "Authentication failed. Check your API key."
        case .rateLimited:
            return "Rate limited by provider. Please wait and try again."
        case .modelNotFound(let model):
            return "Model not found: \(model)"
        case .contextTooLong:
            return "Text exceeds the model's context limit."
        case .providerError(let message):
            return "Provider error: \(message)"
        case .streamingError(let detail):
            return "Streaming error: \(detail)"
        case .invalidResponse:
            return "Invalid response from provider."
        }
    }
}

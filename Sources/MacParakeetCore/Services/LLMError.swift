import Foundation

public enum LLMError: Error, LocalizedError, Sendable {
    case notConfigured
    case connectionFailed(String)
    case authenticationFailed(String?)
    case rateLimited
    case modelNotFound(String)
    case contextTooLong
    case formatterTruncated
    case formatterEmptyResponse
    case providerError(String)
    case streamingError(String)
    case invalidResponse
    case cliError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No LLM provider configured. Set up a provider in Settings."
        case .connectionFailed(let detail):
            return "Connection failed: \(detail)"
        case .authenticationFailed(let detail):
            if let detail, !detail.isEmpty {
                return "Authentication failed: \(detail)"
            }
            return "Authentication failed. Check your API key."
        case .rateLimited:
            return "Rate limited by provider. Please wait and try again."
        case .modelNotFound(let model):
            return "Model not found: \(model)"
        case .contextTooLong:
            return "Text exceeds the model's context limit."
        case .formatterTruncated:
            return "AI formatter output was incomplete."
        case .formatterEmptyResponse:
            return "AI formatter returned an empty response."
        case .providerError(let message):
            return "Provider error: \(message)"
        case .streamingError(let detail):
            return "Streaming error: \(detail)"
        case .invalidResponse:
            return "Invalid response from provider."
        case .cliError(let detail):
            return "CLI error: \(detail)"
        }
    }
}

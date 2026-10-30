import Foundation

public struct AppleIntelligenceGenerationRequest: Sendable, Equatable {
    public let instructions: String?
    public let prompt: String
    public let temperature: Double?
    public let maximumResponseTokens: Int?

    public init(
        instructions: String?,
        prompt: String,
        temperature: Double?,
        maximumResponseTokens: Int?
    ) {
        self.instructions = instructions
        self.prompt = prompt
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }
}

public protocol AppleIntelligenceGenerating: Sendable {
    func currentAvailability() -> AppleIntelligenceAvailability
    func generate(
        request: AppleIntelligenceGenerationRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String
}

public struct UnavailableAppleIntelligenceGenerator: AppleIntelligenceGenerating {
    public init() {}

    public func currentAvailability() -> AppleIntelligenceAvailability {
        .unsupported
    }

    public func generate(
        request: AppleIntelligenceGenerationRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        throw LLMError.connectionFailed(AppleIntelligenceAvailability.unsupported.userMessage)
    }
}

enum AppleIntelligencePromptBuilder {
    static func split(messages: [ChatMessage]) -> (instructions: String?, prompt: String) {
        var instructions: [String] = []
        var turns: [(role: ChatMessage.Role, content: String)] = []
        for message in messages {
            let content = message.modelContent
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            switch message.role {
            case .system:
                instructions.append(content)
            case .user, .assistant:
                turns.append((message.role, content))
            }
        }

        let joinedInstructions = instructions.joined(separator: "\n\n")
        let prompt: String
        if turns.count == 1, turns[0].role == .user {
            prompt = turns[0].content
        } else {
            prompt = turns.map { turn in
                switch turn.role {
                case .user:
                    return "User:\n\(turn.content)"
                case .assistant:
                    return "Assistant:\n\(turn.content)"
                case .system:
                    return turn.content
                }
            }.joined(separator: "\n\n")
        }

        return (
            joinedInstructions.isEmpty ? nil : joinedInstructions,
            prompt
        )
    }

    /// Foundation Models streams cumulative snapshots. Emit only the new suffix.
    /// Compare UTF-8 bytes, not grapheme clusters: a combining mark or emoji ZWJ
    /// continuation can make `hasPrefix` fail while the byte prefix is still valid.
    /// If a snapshot diverges from the already-emitted prefix, skip it rather
    /// than splicing a replacement onto text the UI has already shown.
    static func delta(fromCumulative current: String, previous: String) -> String {
        guard current.utf8.starts(with: previous.utf8) else { return "" }
        return String(decoding: current.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
    }

    static func isCumulativeContinuation(_ current: String, of previous: String) -> Bool {
        current.utf8.starts(with: previous.utf8)
    }
}

/// Folds cumulative Foundation Models snapshots into deltas.
///
/// A snapshot that is not a UTF-8 prefix of text already emitted is a rewrite.
/// Continuing would drop the rest of the answer and still report success, so
/// the reducer throws instead of splicing replacement text onto characters the
/// UI has already shown.
struct AppleIntelligenceStreamReducer {
    private(set) var emitted = ""

    mutating func consume(_ current: String) throws -> String {
        guard emitted.isEmpty || AppleIntelligencePromptBuilder.isCumulativeContinuation(current, of: emitted)
        else {
            throw LLMError.streamingError(
                "Apple Intelligence revised a response that was already shown. Try again."
            )
        }
        let delta = AppleIntelligencePromptBuilder.delta(fromCumulative: current, previous: emitted)
        emitted = current
        return delta
    }
}

enum AppleIntelligenceGenerationFailure: Equatable {
    case exceededContextWindow
    case assetsUnavailable
    case guardrailOrRefusal
    case rateLimited
    case concurrentRequests
    case unsupportedLanguageOrLocale
    case message(String)
}

enum AppleIntelligenceFailureMapper {
    static func llmError(for failure: AppleIntelligenceGenerationFailure) -> LLMError {
        switch failure {
        case .exceededContextWindow:
            return .contextTooLong
        case .assetsUnavailable:
            return .connectionFailed(AppleIntelligenceAvailability.modelNotReady.userMessage)
        case .guardrailOrRefusal:
            return .contentFiltered(
                "Apple Intelligence declined this request. Try rephrasing, or use a different AI provider."
            )
        case .rateLimited:
            return .rateLimited
        case .concurrentRequests:
            return .providerError("Apple Intelligence is busy with another request. Try again.")
        case .unsupportedLanguageOrLocale:
            return .providerError("Apple Intelligence does not support this language on this Mac.")
        case .message(let message):
            return .providerError(message)
        }
    }
}

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

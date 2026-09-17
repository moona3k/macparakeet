#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct FoundationModelsAppleIntelligenceGenerator: AppleIntelligenceGenerating {
    func currentAvailability() -> AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unsupported
            }
        @unknown default:
            return .unsupported
        }
    }

    func generate(
        request: AppleIntelligenceGenerationRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let availability = currentAvailability()
        guard availability == .available else {
            throw LLMError.connectionFailed(availability.userMessage)
        }

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: request.instructions
        )
        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.maximumResponseTokens
        )

        do {
            if let onPartial {
                let stream = session.streamResponse(to: request.prompt, options: options)
                var previous = ""
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    let current = snapshot.content
                    let delta = AppleIntelligencePromptBuilder.delta(
                        fromCumulative: current,
                        previous: previous
                    )
                    if !delta.isEmpty {
                        onPartial(delta)
                    }
                    if AppleIntelligencePromptBuilder.isCumulativeContinuation(current, of: previous) {
                        previous = current
                    }
                }
                // Last prefix-valid snapshot, not a rewritten final frame the UI never saw.
                return previous
            }

            let response = try await session.respond(to: request.prompt, options: options)
            return response.content
        } catch {
            throw AppleIntelligenceErrorMapper.map(error)
        }
    }
}

@available(macOS 26.0, *)
enum AppleIntelligenceErrorMapper {
    static func map(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if let llmError = error as? LLMError {
            return llmError
        }
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return LLMError.providerError(error.localizedDescription)
        }

        switch generationError {
        case .exceededContextWindowSize(_):
            return LLMError.contextTooLong
        case .assetsUnavailable(_):
            return LLMError.connectionFailed(
                AppleIntelligenceAvailability.modelNotReady.userMessage
            )
        case .guardrailViolation(_), .refusal(_, _):
            return LLMError.contentFiltered(
                "Apple Intelligence declined this request. Try rephrasing, or use a different AI provider."
            )
        case .rateLimited(_):
            return LLMError.rateLimited
        case .concurrentRequests(_):
            return LLMError.providerError(
                "Apple Intelligence is busy with another request. Try again."
            )
        case .unsupportedLanguageOrLocale(_):
            return LLMError.providerError(
                "Apple Intelligence does not support this language on this Mac."
            )
        case .unsupportedGuide(_), .decodingFailure(_):
            return LLMError.providerError(generationError.localizedDescription)
        @unknown default:
            return LLMError.providerError(generationError.localizedDescription)
        }
    }
}
#endif

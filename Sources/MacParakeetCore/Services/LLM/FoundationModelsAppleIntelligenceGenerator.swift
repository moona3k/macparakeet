#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct FoundationModelsAppleIntelligenceGenerator: AppleIntelligenceGenerating {
    func currentAvailability() -> AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            if SystemLanguageModel.default.supportsLocale() {
                return .available
            }
            return .localeLimited
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
        guard availability.canGenerate else {
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
                var reducer = AppleIntelligenceStreamReducer()
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    let delta = try reducer.consume(snapshot.content)
                    if !delta.isEmpty {
                        onPartial(delta)
                    }
                }
                // Last prefix-valid snapshot, not a rewritten final frame the UI never saw.
                return reducer.emitted
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
            return AppleIntelligenceFailureMapper.llmError(for: .message(error.localizedDescription))
        }

        let failure: AppleIntelligenceGenerationFailure
        switch generationError {
        case .exceededContextWindowSize(_):
            failure = .exceededContextWindow
        case .assetsUnavailable(_):
            failure = .assetsUnavailable
        case .guardrailViolation(_), .refusal(_, _):
            failure = .guardrailOrRefusal
        case .rateLimited(_):
            failure = .rateLimited
        case .concurrentRequests(_):
            failure = .concurrentRequests
        case .unsupportedLanguageOrLocale(_):
            failure = .unsupportedLanguageOrLocale
        case .unsupportedGuide(_), .decodingFailure(_):
            failure = .message(generationError.localizedDescription)
        @unknown default:
            failure = .message(generationError.localizedDescription)
        }
        return AppleIntelligenceFailureMapper.llmError(for: failure)
    }
}
#endif

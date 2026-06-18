import Foundation
import OSLog

struct FormatterOutcome: Sendable {
    let text: String?
    let run: LLMRun?
    let resolution: AIFormatterPromptResolution?

    static let skipped = FormatterOutcome(text: nil, run: nil, resolution: nil)
}

struct TranscriptFormatter: Sendable {
    let llmService: LLMServiceProtocol?
    let shouldUseAIFormatter: @Sendable () -> Bool
    let logger: Logger

    func format(
        _ text: String,
        runSource: LLMRunSource?,
        lane: Lane,
        resolvePrompt: @Sendable () async -> (template: String, resolution: AIFormatterPromptResolution?)
    ) async throws -> FormatterOutcome {
        guard shouldUseAIFormatter(), let llmService else {
            return .skipped
        }

        // The formatter rewrites the full text, so output length tracks input
        // length; past the cap slow providers can stall finalization until
        // timeout before falling back anyway (issue #493).
        if let maxInputChars = lane.maxInputChars, text.count > maxInputChars {
            logger.info("transcription_ai_formatter_skipped reason=input_too_long chars=\(text.count, privacy: .public) cap=\(maxInputChars, privacy: .public)")
            return .skipped
        }

        if lane.postsLifecycleNotifications {
            // Notify observers (e.g. the dictation flow coordinator) that the
            // LLM formatter is about to run so the overlay pill can switch to
            // its `.formatting` beat. We only post this *after* the guards
            // above so "formatter disabled" dictations never flicker into the
            // formatting visual.
            NotificationCenter.default.post(
                name: .macParakeetAIFormatterDidStart,
                object: nil,
                userInfo: ["source": lane.notificationSource]
            )
        }
        defer {
            if lane.postsLifecycleNotifications {
                NotificationCenter.default.post(
                    name: .macParakeetAIFormatterDidFinish,
                    object: nil,
                    userInfo: ["source": lane.notificationSource]
                )
            }
        }

        let (promptTemplate, resolution) = await resolvePrompt()
        // Normalize before comparing: `AIFormatter.renderPrompt` passes the
        // template through `normalizedPromptTemplate` before sending, which
        // trims whitespace and folds legacy-v1 prompts back onto the current
        // default. Raw comparison would report those cases as custom prompts
        // even though the LLM sees the shipped default.
        let defaultPromptUsed = AIFormatter.normalizedPromptTemplate(promptTemplate)
            == AIFormatter.defaultPromptTemplate
        let startedAt = Date()
        do {
            let result = try await llmService.formatTranscriptDetailed(
                transcript: text,
                promptTemplate: promptTemplate,
                source: lane.telemetrySource,
                defaultPromptUsed: defaultPromptUsed
            )
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let run = runSource.map {
                LLMRun(formatterResult: result, source: $0, feature: lane.feature)
            }
            return FormatterOutcome(text: trimmed.isEmpty ? nil : trimmed, run: run, resolution: resolution)
        } catch {
            if error is CancellationError {
                throw error
            }
            let errorType = TelemetryErrorClassifier.classify(error)
            switch lane {
            case .dictation:
                logger.warning("dictation_ai_formatter_failed fallback=standard_cleanup error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            case .transcription:
                logger.warning("transcription_ai_formatter_failed fallback=standard_cleanup error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            }
            let message = "\(error.localizedDescription) Used standard cleanup."
            NotificationCenter.default.post(
                name: .macParakeetAIFormatterWarning,
                object: nil,
                userInfo: [
                    "source": lane.notificationSource,
                    "message": message,
                ]
            )
            let run = runSource.map {
                LLMRun.failedFormatterRun(
                    source: $0,
                    feature: lane.feature,
                    errorType: errorType,
                    inputChars: text.count,
                    defaultPromptUsed: defaultPromptUsed,
                    startedAt: startedAt
                )
            }
            // Drop the routing resolution on the failure path: formatting did
            // not run, so the dictation falls back to standard cleanup. Keeping
            // the resolution here would stamp the matched profile onto the saved
            // record (see the provenance write in stopRecording), making History
            // claim "Formatted with the '<profile>' prompt" for text that was
            // never formatted by it. The failed `run` still records the attempt
            // for telemetry.
            return FormatterOutcome(text: nil, run: run, resolution: nil)
        }
    }
}

extension TranscriptFormatter {
    enum Lane: Sendable {
        case dictation
        case transcription

        var telemetrySource: TelemetryFormatterSource {
            switch self {
            case .dictation:
                .dictation
            case .transcription:
                .transcription
            }
        }

        var feature: LLMRun.Feature {
            switch self {
            case .dictation:
                .formatterDictation
            case .transcription:
                .formatterTranscription
            }
        }

        var maxInputChars: Int? {
            switch self {
            case .dictation:
                nil
            case .transcription:
                AIFormatter.maxTranscriptionInputChars
            }
        }

        var postsLifecycleNotifications: Bool {
            switch self {
            case .dictation:
                true
            case .transcription:
                false
            }
        }

        var notificationSource: String {
            switch self {
            case .dictation:
                "dictation"
            case .transcription:
                "transcription"
            }
        }
    }
}

import Foundation

/// Generates and persists a saved meeting's normal enabled auto-run prompt
/// results (summaries) against an already-transcribed `Transcription` row,
/// reusing the exact prompt selection, assembly, provider/privacy routing
/// and result-persistence behavior the GUI and CLI already use. This does
/// not transcribe, format, title, materialize meeting artifacts beyond a
/// refresh, or manage audio/retention — callers own those effects.
///
/// Scoped for the split-and-transcribe first-processing stage: a brand new
/// saved child receiving its first transcription and its first completion
/// pass. Retrying this call for the same child skips prompts that already
/// have a saved `PromptResult` for that prompt id — this dedup is
/// intentionally scoped to first-processing retry (the child has never
/// been resummarized before), not a general "never regenerate" policy for
/// meetings a user has explicitly asked to re-run.
public protocol SavedAudioAutoPromptCompletionServicing: Sendable {
    @discardableResult
    func completeAutoPrompts(
        for transcription: Transcription,
        onProgress: (@Sendable (SavedAudioAutoPromptCompletionProgress) -> Void)?
    ) async throws -> SavedAudioAutoPromptCompletionResult
}

public extension SavedAudioAutoPromptCompletionServicing {
    @discardableResult
    func completeAutoPrompts(for transcription: Transcription) async throws -> SavedAudioAutoPromptCompletionResult {
        try await completeAutoPrompts(for: transcription, onProgress: nil)
    }
}

public struct SavedAudioAutoPromptCompletionProgress: Sendable, Equatable {
    public let completedCount: Int
    public let totalCount: Int
    public let promptName: String

    public init(completedCount: Int, totalCount: Int, promptName: String) {
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.promptName = promptName
    }
}

public struct SavedAudioAutoPromptCompletionResult: Sendable, Equatable {
    public struct PromptOutcome: Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            /// A new `PromptResult` was generated and saved this call.
            case generated(promptResultID: UUID)
            /// Skipped: this prompt already had a saved result for this
            /// child, from an earlier attempt at this same first-processing
            /// completion. Nothing was regenerated or duplicated.
            case alreadyCompleted(promptResultID: UUID)
            /// The provider/persistence step failed for this prompt only.
            /// Other prompts still ran; this one is retryable independently.
            case failed(message: String)
        }

        public let promptId: UUID?
        public let promptName: String
        public let status: Status

        public init(promptId: UUID?, promptName: String, status: Status) {
            self.promptId = promptId
            self.promptName = promptName
            self.status = status
        }
    }

    /// One entry per auto-run prompt that was selected for this meeting.
    /// Empty when the transcript was blank or no prompt is enabled/applicable.
    public var outcomes: [PromptOutcome]

    public init(outcomes: [PromptOutcome] = []) {
        self.outcomes = outcomes
    }

    public var hasFailures: Bool {
        outcomes.contains {
            if case .failed = $0.status { return true }
            return false
        }
    }
}

public final class SavedAudioAutoPromptCompletionService: SavedAudioAutoPromptCompletionServicing, @unchecked Sendable {
    private let promptRepo: PromptRepositoryProtocol
    private let promptResultRepo: PromptResultRepositoryProtocol
    private let llmService: LLMServiceProtocol
    private let promptLabelPolicyRepository: PromptLabelPolicyRepositoryProtocol?
    private let transcriptionLabelRepository: TranscriptionMeetingLabelRepositoryProtocol?
    private let promptApplicabilityResolver: PromptApplicabilityResolver?
    private let speakerAttributionReader: SpeakerAttributionReading?
    private let meetingArtifactStore: MeetingArtifactStoring?
    /// Optional: knowledge-card generation runs alongside auto-prompts in the
    /// GUI's completion path (`PromptResultsViewModel.generateKnowledgeCard`).
    /// Reused as-is here — fire-and-forget, best effort, never blocks or
    /// fails prompt completion.
    private let cardGenerator: CardGenerating?

    public init(
        promptRepo: PromptRepositoryProtocol,
        promptResultRepo: PromptResultRepositoryProtocol,
        llmService: LLMServiceProtocol,
        promptLabelPolicyRepository: PromptLabelPolicyRepositoryProtocol? = nil,
        transcriptionLabelRepository: TranscriptionMeetingLabelRepositoryProtocol? = nil,
        promptApplicabilityResolver: PromptApplicabilityResolver? = nil,
        speakerAttributionReader: SpeakerAttributionReading? = nil,
        meetingArtifactStore: MeetingArtifactStoring? = nil,
        cardGenerator: CardGenerating? = nil
    ) {
        self.promptRepo = promptRepo
        self.promptResultRepo = promptResultRepo
        self.llmService = llmService
        self.promptLabelPolicyRepository = promptLabelPolicyRepository
        self.transcriptionLabelRepository = transcriptionLabelRepository
        self.promptApplicabilityResolver = promptApplicabilityResolver
        self.speakerAttributionReader = speakerAttributionReader
        self.meetingArtifactStore = meetingArtifactStore
        self.cardGenerator = cardGenerator
    }

    @discardableResult
    public func completeAutoPrompts(
        for transcription: Transcription,
        onProgress: (@Sendable (SavedAudioAutoPromptCompletionProgress) -> Void)? = nil
    ) async throws -> SavedAudioAutoPromptCompletionResult {
        let transcript = effectiveTranscript(for: transcription)
        guard transcript.contains(where: { !$0.isWhitespace }) else {
            return SavedAudioAutoPromptCompletionResult()
        }

        generateKnowledgeCardIfConfigured(transcriptionId: transcription.id)

        let labelIDs = try transcriptionLabelRepository?.labelIDs(for: transcription.id) ?? []
        let visiblePrompts = try promptRepo.fetchVisible(category: .result)
        let autoPrompts = try PromptAutoRunSelector.autoRunPrompts(
            prompts: visiblePrompts,
            sourceType: transcription.sourceType,
            meetingTypeId: transcription.meetingTypeId,
            transcriptionLabelIDs: labelIDs,
            promptLabelPolicyRepository: promptLabelPolicyRepository,
            promptApplicabilityResolver: promptApplicabilityResolver
        )
        guard !autoPrompts.isEmpty else {
            return SavedAudioAutoPromptCompletionResult()
        }

        let existingResults = try promptResultRepo.fetchAll(transcriptionId: transcription.id)
        var outcomes: [SavedAudioAutoPromptCompletionResult.PromptOutcome] = []
        for (index, prompt) in autoPrompts.enumerated() {
            try Task.checkCancellation()
            onProgress?(SavedAudioAutoPromptCompletionProgress(
                completedCount: index,
                totalCount: autoPrompts.count,
                promptName: prompt.name
            ))

            if let existing = existingResults.first(where: { $0.promptId == prompt.id }) {
                outcomes.append(.init(
                    promptId: prompt.id,
                    promptName: prompt.name,
                    status: .alreadyCompleted(promptResultID: existing.id)
                ))
                continue
            }

            do {
                let saved = try await generateAndSave(prompt: prompt, transcript: transcript, transcription: transcription)
                outcomes.append(.init(promptId: prompt.id, promptName: prompt.name, status: .generated(promptResultID: saved.id)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcomes.append(.init(promptId: prompt.id, promptName: prompt.name, status: .failed(message: error.localizedDescription)))
            }
        }

        onProgress?(SavedAudioAutoPromptCompletionProgress(
            completedCount: autoPrompts.count,
            totalCount: autoPrompts.count,
            promptName: ""
        ))
        await refreshMeetingArtifactsIfConfigured(transcription: transcription)

        return SavedAudioAutoPromptCompletionResult(outcomes: outcomes)
    }

    private func generateAndSave(
        prompt: Prompt,
        transcript: String,
        transcription: Transcription
    ) async throws -> PromptResult {
        let assembly = PromptSystemPromptAssembler.assembleDetailed(
            promptContent: prompt.content,
            extraInstructions: nil,
            includeMeetingNotes: prompt.includeMeetingNotes,
            userNotes: transcription.userNotes,
            transcript: transcript
        )
        let result = try await llmService.generatePromptResultDetailed(
            transcript: transcript,
            systemPrompt: assembly.systemPrompt,
            inferenceSettings: prompt.inferenceSettings,
            modelOverride: prompt.modelOverride
        )
        guard result.output.contains(where: { !$0.isWhitespace }) else {
            throw LLMError.providerError("Prompt result returned an empty response")
        }
        let promptResult = PromptResult(
            transcriptionId: transcription.id,
            promptId: prompt.id,
            promptVersionId: prompt.activeVersionId,
            promptName: prompt.name,
            promptContent: prompt.content,
            extraInstructions: nil,
            content: result.output,
            userNotesSnapshot: assembly.effectiveUserNotes,
            includeMeetingNotesSnapshot: prompt.includeMeetingNotes,
            inferenceSettingsSnapshot: result.effectiveSettings,
            providerSnapshot: result.provider,
            modelSnapshot: result.model
        )
        try promptResultRepo.save(promptResult)
        return promptResult
    }

    private func effectiveTranscript(for transcription: Transcription) -> String {
        guard let speakerAttributionReader,
              let projection = try? speakerAttributionReader.resolve(transcription: transcription)
        else {
            return TranscriptAIContextFormatter.format(transcription: transcription)
        }
        return TranscriptAIContextFormatter.format(projection: projection)
    }

    private func generateKnowledgeCardIfConfigured(transcriptionId: UUID) {
        guard let cardGenerator else { return }
        Task.detached(priority: .utility) {
            _ = try? await cardGenerator.generate(transcriptionId: transcriptionId, force: false)
        }
    }

    private func refreshMeetingArtifactsIfConfigured(transcription: Transcription) async {
        guard let meetingArtifactStore, transcription.sourceType == .meeting else { return }
        do {
            let promptResults = try promptResultRepo.fetchAll(transcriptionId: transcription.id)
            if let speakerAttributionReader,
               let projection = try? speakerAttributionReader.resolve(transcription: transcription) {
                _ = try await meetingArtifactStore.materialize(projection: projection, promptResults: promptResults)
            } else {
                _ = try await meetingArtifactStore.materialize(transcription: transcription, promptResults: promptResults)
            }
        } catch {
            // Best-effort refresh: a stale artifact is repairable later and
            // must never revert an already-saved PromptResult.
        }
    }
}

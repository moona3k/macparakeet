import Foundation
import MacParakeetCore

/// Shared CLI construction for operations that turn already-managed meeting
/// audio into a transcript and its enabled post-processing. Keeping it here
/// prevents import and split from silently diverging in speech, diarization,
/// prompt, card, or configured-recordings-root behavior.
struct SavedMeetingProcessingContext {
    let transcriptionService: TranscriptionService
    let completionService: SavedAudioAutoPromptCompletionService
    let recordingsRootURL: URL

    init(dbManager: DatabaseManager, transcriptionRepo: TranscriptionRepository) throws {
        let dbQueue = dbManager.dbQueue
        let defaults = AppPaths.appDefaults()
        let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)
        let llmService = LLMService()
        let promptRepo = PromptRepository(dbQueue: dbQueue)
        let promptResultRepo = PromptResultRepository(dbQueue: dbQueue)
        let promptLabelPolicyRepository = PromptLabelPolicyRepository(dbQueue: dbQueue)
        let transcriptionLabelRepository = TranscriptionMeetingLabelRepository(dbQueue: dbQueue)
        let speakerAttributionReader = SpeakerAttributionReadService(dbQueue: dbQueue)
        let cardRepository = CardRepository(dbQueue: dbQueue)
        let customWordRepo = CustomWordRepository(dbQueue: dbQueue)
        let segmentRepo = SegmentRepository(dbQueue: dbQueue)
        let knowledgeLayerMutator = KnowledgeLayerMutationService(dbQueue: dbQueue)
        let snippetRepo = TextSnippetRepository(dbQueue: dbQueue)

        let sttClient = STTClient(
            parakeetModelVariant: SpeechEnginePreference.parakeetModelVariant(defaults: defaults),
            speechEngine: SpeechEnginePreference.finalTranscription(defaults: defaults),
            nemotronModelVariant: SpeechEnginePreference.nemotronModelVariant(defaults: defaults),
            whisperModelVariant: SpeechEnginePreference.whisperModelVariant(defaults: defaults),
            defaults: defaults,
            customWordRepository: customWordRepo
        )
        let artifactStore = MeetingArtifactStore(speakerAttributionReader: speakerAttributionReader)
        transcriptionService = TranscriptionService(
            audioProcessor: AudioProcessor(),
            sttTranscriber: sttClient,
            transcriptionRepo: transcriptionRepo,
            segmentRepo: segmentRepo,
            knowledgeLayerMutator: knowledgeLayerMutator,
            promptResultRepo: promptResultRepo,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            processingMode: { preferences.processingMode },
            llmService: llmService,
            llmRunRepo: LLMRunRepository(dbQueue: dbQueue),
            shouldUseAIFormatter: { preferences.aiFormatterEnabled && preferences.aiFormatterEnabledForTranscriptions },
            aiFormatterPromptTemplate: { preferences.aiFormatterPrompt },
            shouldAutoGenerateMeetingTitles: { preferences.shouldAutoGenerateMeetingTitles },
            shouldDiarize: { preferences.shouldDiarize },
            shouldDiarizeMeetings: { preferences.shouldDiarizeMeetings },
            fileSpeechEngineSelection: { SpeechEngineSelection.finalTranscription(defaults: defaults) },
            diarizationService: DiarizationService(),
            meetingArtifactStore: artifactStore
        )
        completionService = SavedAudioAutoPromptCompletionService(
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            llmService: llmService,
            promptLabelPolicyRepository: promptLabelPolicyRepository,
            transcriptionLabelRepository: transcriptionLabelRepository,
            speakerAttributionReader: speakerAttributionReader,
            meetingArtifactStore: artifactStore,
            cardGenerator: CardGenerationService(
                transcriptionRepository: transcriptionRepo,
                segmentRepository: segmentRepo,
                cardRepository: cardRepository,
                speakerAttributionReader: speakerAttributionReader,
                completionProvider: llmService
            )
        )
        recordingsRootURL = meetingRecordingsRootURL(defaults: defaults)
    }
}

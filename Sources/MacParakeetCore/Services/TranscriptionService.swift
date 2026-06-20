import Foundation
import OSLog

public protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func transcribeTransient(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func transcribeMeeting(
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    /// Creates and persists the pre-STT meeting row. Must not run speech-to-text.
    func prepareMeetingTranscription(
        recording: MeetingRecordingOutput
    ) async throws -> Transcription
    /// Finalizes the existing meeting row. Must update `transcriptionID`
    /// rather than inserting another row.
    func finalizeMeetingTranscription(
        recording: MeetingRecordingOutput,
        updating transcriptionID: UUID,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func transcribeURL(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> Transcription
    func transcribeURLTransient(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> Transcription
}

public protocol SpeechEngineOverrideTranscriptionService: TranscriptionServiceProtocol {
    func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
}

/// Metadata that pre-resolution (e.g. an Apple Podcasts iTunes lookup or RSS
/// feed parse) supplies for a downloaded media URL. When present, these fields
/// win over the generic metadata inferred from a raw enclosure URL.
private struct ResolvedMediaMetadata: Sendable {
    let title: String?
    let channelName: String?
    let thumbnailURL: String?
    let description: String?
    let durationSeconds: Int?

    init(podcast: ResolvedPodcastEpisode) {
        self.title = podcast.episodeTitle
        self.channelName = podcast.showName
        self.thumbnailURL = podcast.artworkURL
        self.description = podcast.episodeDescription
        self.durationSeconds = podcast.durationSeconds
    }
}

extension TranscriptionServiceProtocol {
    public func transcribe(fileURL: URL) async throws -> Transcription {
        try await transcribe(fileURL: fileURL, source: .file, onProgress: nil)
    }

    public func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource
    ) async throws -> Transcription {
        try await transcribe(fileURL: fileURL, source: source, onProgress: nil)
    }

    public func transcribeTransient(fileURL: URL) async throws -> Transcription {
        try await transcribeTransient(fileURL: fileURL, source: .file, onProgress: nil)
    }

    public func transcribeTransient(
        fileURL: URL,
        source: TelemetryTranscriptionSource
    ) async throws -> Transcription {
        try await transcribeTransient(fileURL: fileURL, source: source, onProgress: nil)
    }

    public func transcribeURL(urlString: String) async throws -> Transcription {
        try await transcribeURL(urlString: urlString, onProgress: nil)
    }

    public func transcribeURLTransient(urlString: String) async throws -> Transcription {
        try await transcribeURLTransient(urlString: urlString, onProgress: nil)
    }

    public func transcribeMeeting(recording: MeetingRecordingOutput) async throws -> Transcription {
        try await transcribeMeeting(recording: recording, onProgress: nil)
    }

    public func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        try await transcribe(fileURL: fileURL, source: source, onProgress: onProgress)
    }

    public func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        try await transcribeMeeting(recording: recording, onProgress: onProgress)
    }

    public func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        guard let speechEngineOverride else {
            return try await retranscribe(
                existing: transcription,
                fileURL: fileURL,
                source: source,
                onProgress: onProgress
            )
        }
        guard let routedService = self as? any SpeechEngineOverrideTranscriptionService else {
            throw STTError.engineStartFailed(
                "Pinned \(speechEngineOverride.engine.rawValue) speech engine cannot be honored by this transcription service."
            )
        }
        return try await routedService.retranscribe(
            existing: transcription,
            fileURL: fileURL,
            source: source,
            speechEngineOverride: speechEngineOverride,
            onProgress: onProgress
        )
    }

    public func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        guard let speechEngineOverride else {
            return try await retranscribeMeeting(
                existing: transcription,
                recording: recording,
                onProgress: onProgress
            )
        }
        guard let routedService = self as? any SpeechEngineOverrideTranscriptionService else {
            throw STTError.engineStartFailed(
                "Pinned \(speechEngineOverride.engine.rawValue) speech engine cannot be honored by this transcription service."
            )
        }
        return try await routedService.retranscribeMeeting(
            existing: transcription,
            recording: recording,
            speechEngineOverride: speechEngineOverride,
            onProgress: onProgress
        )
    }
}

private struct TranscriptionOperationContext: Sendable {
    let operationContext: ObservabilityOperationContext
    let source: TelemetryTranscriptionSource
    let inputKind: ObservabilityInputKind?
    let mediaExtension: String?
    let fileSizeBucket: String?
    /// Recognized origin platform for a URL ingest (youtube/vimeo/.../other);
    /// `nil` for file and meeting lanes, where platform has no meaning.
    let urlPlatform: TelemetryURLPlatform?

    init(
        source: TelemetryTranscriptionSource,
        inputKind: ObservabilityInputKind?,
        mediaExtension: String?,
        fileSizeBucket: String?,
        urlPlatform: TelemetryURLPlatform? = nil,
        operationContext: ObservabilityOperationContext = Observability.childOperationContext()
    ) {
        self.operationContext = operationContext
        self.source = source
        self.inputKind = inputKind
        self.mediaExtension = mediaExtension
        self.fileSizeBucket = fileSizeBucket
        self.urlPlatform = urlPlatform
    }
}

public actor TranscriptionService: SpeechEngineOverrideTranscriptionService {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "TranscriptionService")
    private let audioProcessor: AudioProcessorProtocol
    private let sttTranscriber: STTTranscribing
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let entitlements: EntitlementsChecking?
    private let customWordRepo: CustomWordRepositoryProtocol?
    private let snippetRepo: TextSnippetRepositoryProtocol?
    private let processingMode: @Sendable () -> Dictation.ProcessingMode
    private let textRefinementService: TextRefinementService
    private let llmService: LLMServiceProtocol?
    private let llmRunRecorder: LLMRunRecorder
    private let shouldUseAIFormatter: @Sendable () -> Bool
    private let aiFormatterPromptTemplate: @Sendable () -> String
    private let shouldAutoGenerateMeetingTitles: @Sendable () -> Bool
    private let shouldKeepDownloadedAudio: @Sendable () -> Bool
    private let shouldDiarize: @Sendable () -> Bool
    private let youtubeDownloader: YouTubeDownloading?
    private let podcastResolver: PodcastResolving?
    private let podcastSearchResolver: PodcastSearchResolving?
    private let podcastAudioFetcher: PodcastAudioFetching?
    private let promptResultRepo: PromptResultRepositoryProtocol?
    private let diarizationService: DiarizationServiceProtocol?
    private let mediaMetadataExtractor: MediaMetadataExtracting
    private let thumbnailCache: ThumbnailCaching
    private let playbackConverter: YouTubeAudioPlaybackConverting
    private let meetingArtifactStore: MeetingArtifactStoring?
    private let meetingAutomationHookRunner: MeetingAutomationHookRunning?

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttTranscriber: STTTranscribing,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        promptResultRepo: PromptResultRepositoryProtocol? = nil,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        llmService: LLMServiceProtocol? = nil,
        llmRunRepo: LLMRunRepositoryProtocol? = nil,
        shouldUseAIFormatter: (@Sendable () -> Bool)? = nil,
        aiFormatterPromptTemplate: (@Sendable () -> String)? = nil,
        shouldAutoGenerateMeetingTitles: (@Sendable () -> Bool)? = nil,
        shouldKeepDownloadedAudio: (@Sendable () -> Bool)? = nil,
        shouldDiarize: (@Sendable () -> Bool)? = nil,
        youtubeDownloader: YouTubeDownloading? = nil,
        podcastResolver: PodcastResolving? = nil,
        podcastSearchResolver: PodcastSearchResolving? = nil,
        podcastAudioFetcher: PodcastAudioFetching? = nil,
        diarizationService: DiarizationServiceProtocol? = nil,
        mediaMetadataExtractor: MediaMetadataExtracting = AVMediaMetadataExtractor(),
        thumbnailCache: ThumbnailCaching = ThumbnailCacheService.shared,
        playbackConverter: YouTubeAudioPlaybackConverting = YouTubeAudioPlaybackConverter(),
        meetingArtifactStore: MeetingArtifactStoring? = MeetingArtifactStore(),
        meetingAutomationHookRunner: MeetingAutomationHookRunning? = MeetingAutomationHookRunner()
    ) {
        self.audioProcessor = audioProcessor
        self.sttTranscriber = sttTranscriber
        self.transcriptionRepo = transcriptionRepo
        self.entitlements = entitlements
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.processingMode = processingMode ?? { .raw }
        self.textRefinementService = TextRefinementService()
        self.llmService = llmService
        self.llmRunRecorder = LLMRunRecorder(repository: llmRunRepo)
        self.shouldUseAIFormatter = shouldUseAIFormatter ?? { false }
        self.aiFormatterPromptTemplate = aiFormatterPromptTemplate ?? { AIFormatter.defaultPromptTemplate }
        self.shouldAutoGenerateMeetingTitles = shouldAutoGenerateMeetingTitles ?? { false }
        self.shouldKeepDownloadedAudio = shouldKeepDownloadedAudio ?? { true }
        self.shouldDiarize = shouldDiarize ?? { true }
        self.youtubeDownloader = youtubeDownloader
        self.podcastResolver = podcastResolver
        self.podcastSearchResolver = podcastSearchResolver
        self.podcastAudioFetcher = podcastAudioFetcher
        self.promptResultRepo = promptResultRepo
        self.diarizationService = diarizationService
        self.mediaMetadataExtractor = mediaMetadataExtractor
        self.thumbnailCache = thumbnailCache
        self.playbackConverter = playbackConverter
        self.meetingArtifactStore = meetingArtifactStore
        self.meetingAutomationHookRunner = meetingAutomationHookRunner
    }

    public func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource = .file,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        try await transcribe(
            fileURL: fileURL,
            source: source,
            persistResult: true,
            onProgress: onProgress
        )
    }

    public func transcribeTransient(
        fileURL: URL,
        source: TelemetryTranscriptionSource = .file,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        try await transcribe(
            fileURL: fileURL,
            source: source,
            persistResult: false,
            onProgress: onProgress
        )
    }

    private func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        persistResult: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let sourceType: Transcription.SourceType = switch source {
        case .youtube:
            .youtube
        case .podcast:
            .podcast
        case .meeting:
            .meeting
        case .file, .dragDrop:
            .file
        }
        return try await transcribe(
            fileURL: fileURL,
            storedFileURL: fileURL,
            displayFileName: nil,
            source: source,
            sttJob: .fileTranscription,
            sourceType: sourceType,
            persistResult: persistResult,
            onProgress: onProgress
        )
    }

    public func transcribeMeeting(
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let operation = meetingOperationContext(for: recording)

        return try await Observability.withOperationContext(operation.operationContext) {
            try await assertCanTranscribeOrEmitPreflight(
                operation,
                audioDurationSeconds: recording.durationSeconds
            )

            var transcription = makeMeetingTranscriptionStub(recording: recording)
            do {
                try transcriptionRepo.save(transcription)
            } catch {
                sendTranscriptionOperation(
                    operation,
                    outcome: .failure,
                    stage: .persistence,
                    audioDurationSeconds: recording.durationSeconds,
                    errorType: Self.errorType(for: error)
                )
                throw error
            }
            Telemetry.send(.transcriptionStarted(
                source: .meeting,
                audioDurationSeconds: recording.durationSeconds
            ))

            return try await transcribeMeetingAudio(
                recording: recording,
                transcription: &transcription,
                operation: operation,
                onProgress: onProgress
            )
        }
    }

    public func prepareMeetingTranscription(
        recording: MeetingRecordingOutput
    ) async throws -> Transcription {
        let transcription = makeMeetingTranscriptionStub(recording: recording)
        try transcriptionRepo.save(transcription)
        return transcription
    }

    public func finalizeMeetingTranscription(
        recording: MeetingRecordingOutput,
        updating transcriptionID: UUID,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let operation = meetingOperationContext(for: recording)

        return try await Observability.withOperationContext(operation.operationContext) {
            try await assertCanTranscribeOrEmitPreflight(
                operation,
                audioDurationSeconds: recording.durationSeconds
            )

            guard var transcription = try transcriptionRepo.fetch(id: transcriptionID) else {
                throw STTError.transcriptionFailed("Missing queued meeting transcription row.")
            }
            transcription.fileName = transcription.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? recording.displayName
                : transcription.fileName
            transcription.filePath = transcription.filePath ?? recording.mixedAudioURL.path
            transcription.meetingArtifactFolderPath = transcription.meetingArtifactFolderPath ?? recording.folderURL.path
            transcription.fileSizeBytes = transcription.fileSizeBytes ?? meetingFileSize(for: recording)
            transcription.durationMs = transcription.durationMs ?? Int((recording.durationSeconds * 1000).rounded())
            transcription.sourceType = .meeting
            transcription.status = .processing
            transcription.errorMessage = nil
            transcription.userNotes = transcription.userNotes ?? recording.userNotes
            transcription.updatedAt = Date()
            try transcriptionRepo.save(transcription)

            Telemetry.send(.transcriptionStarted(
                source: .meeting,
                audioDurationSeconds: recording.durationSeconds
            ))

            return try await transcribeMeetingAudio(
                recording: recording,
                transcription: &transcription,
                operation: operation,
                onProgress: onProgress
            )
        }
    }

    public func retranscribe(
        existing original: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        try await retranscribe(
            existing: original,
            fileURL: fileURL,
            source: source,
            speechEngineOverride: nil,
            onProgress: onProgress
        )
    }

    public func retranscribe(
        existing original: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        speechEngineOverride: SpeechEngineSelection? = nil,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        var transcription = makeRetranscriptionRecord(from: original)
        transcription.fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
            .flatMap { $0 } ?? original.fileSizeBytes
        let operation = TranscriptionOperationContext(
            source: source,
            inputKind: Observability.inputKind(for: fileURL),
            mediaExtension: Observability.mediaExtension(for: fileURL),
            fileSizeBucket: Observability.fileSizeBucket(bytes: transcription.fileSizeBytes)
        )

        return try await Observability.withOperationContext(operation.operationContext) {
            try await assertCanTranscribeOrEmitPreflight(operation)

            Telemetry.send(.transcriptionStarted(source: source, audioDurationSeconds: nil))

            return try await transcribeAudio(
                fileURL: fileURL,
                source: source,
                sttJob: .fileTranscription,
                transcription: &transcription,
                operation: operation,
                tempFiles: [],
                persistFailureStatus: false,
                speechEngine: speechEngineOverride,
                onProgress: onProgress
            )
        }
    }

    public func retranscribeMeeting(
        existing original: Transcription,
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        try await retranscribeMeeting(
            existing: original,
            recording: recording,
            speechEngineOverride: nil,
            onProgress: onProgress
        )
    }

    public func retranscribeMeeting(
        existing original: Transcription,
        recording: MeetingRecordingOutput,
        speechEngineOverride: SpeechEngineSelection? = nil,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        var transcription = makeRetranscriptionRecord(from: original)
        transcription.fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: recording.mixedAudioURL.path)[.size] as? Int)
            .flatMap { $0 } ?? original.fileSizeBytes
        transcription.userNotes = original.userNotes ?? recording.userNotes
        let operation = TranscriptionOperationContext(
            source: .meeting,
            inputKind: .meeting,
            mediaExtension: Observability.mediaExtension(for: recording.mixedAudioURL),
            fileSizeBucket: Observability.fileSizeBucket(bytes: transcription.fileSizeBytes)
        )

        return try await Observability.withOperationContext(operation.operationContext) {
            try await assertCanTranscribeOrEmitPreflight(
                operation,
                audioDurationSeconds: recording.durationSeconds
            )

            Telemetry.send(.transcriptionStarted(
                source: .meeting,
                audioDurationSeconds: recording.durationSeconds
            ))

            return try await transcribeMeetingAudio(
                recording: recording,
                transcription: &transcription,
                operation: operation,
                persistFailureStatus: false,
                speechEngineOverride: speechEngineOverride,
                onProgress: onProgress
            )
        }
    }

    private func transcribe(
        fileURL: URL,
        storedFileURL: URL?,
        displayFileName: String?,
        source: TelemetryTranscriptionSource,
        sttJob: STTJobKind,
        sourceType: Transcription.SourceType,
        persistResult: Bool = true,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let embeddedMetadata = sourceType == .file
            ? await mediaMetadataExtractor.metadata(for: fileURL)
            : .empty
        let fileName = Self.firstNonEmpty(
            displayFileName,
            embeddedMetadata.title,
            storedFileURL?.lastPathComponent,
            fileURL.lastPathComponent
        ) ?? fileURL.lastPathComponent
        let fileSize = storedFileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int).flatMap { $0 }
        }
        let operation = TranscriptionOperationContext(
            source: source,
            inputKind: source == .youtube ? .youtube : Observability.inputKind(for: fileURL),
            mediaExtension: Observability.mediaExtension(for: fileURL),
            fileSizeBucket: Observability.fileSizeBucket(bytes: fileSize)
        )

        return try await Observability.withOperationContext(operation.operationContext) {
            try await assertCanTranscribeOrEmitPreflight(operation)

            var transcription = Transcription(
                fileName: fileName,
                filePath: storedFileURL?.path,
                fileSizeBytes: fileSize,
                durationMs: embeddedMetadata.durationMs,
                language: nil,
                status: .processing,
                channelName: embeddedMetadata.author,
                videoDescription: embeddedMetadata.description,
                sourceType: sourceType
            )
            if persistResult {
                do {
                    try transcriptionRepo.save(transcription)
                } catch {
                    sendTranscriptionOperation(
                        operation,
                        outcome: .failure,
                        stage: .persistence,
                        errorType: Self.errorType(for: error)
                    )
                    throw error
                }
                await cacheEmbeddedArtworkIfPresent(embeddedMetadata, for: transcription.id)
            }
            Telemetry.send(.transcriptionStarted(source: source, audioDurationSeconds: nil))

            // Extract a representative frame when no embedded artwork was available.
            if persistResult, embeddedMetadata.artworkData == nil, Self.isVideoFile(fileURL) {
                let transcriptionId = transcription.id
                let path = fileURL.path
                let logger = self.logger
                let thumbnailCache = self.thumbnailCache
                Task.detached(priority: .utility) {
                    do {
                        _ = try await thumbnailCache.extractVideoFrame(from: path, for: transcriptionId)
                    } catch {
                        logger.error("transcription_thumbnail_extract_failed id=\(transcriptionId, privacy: .public) error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
                    }
                }
            }

            return try await transcribeAudio(
                fileURL: fileURL,
                source: source,
                sttJob: sttJob,
                transcription: &transcription,
                operation: operation,
                tempFiles: [],
                persistResult: persistResult,
                onProgress: onProgress
            )
        }
    }

    public func transcribeURL(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil) async throws -> Transcription {
        try await transcribeURL(
            urlString: urlString,
            persistResult: true,
            onProgress: onProgress
        )
    }

    public func transcribeURLTransient(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil) async throws -> Transcription {
        try await transcribeURL(
            urlString: urlString,
            persistResult: false,
            onProgress: onProgress
        )
    }

    private func transcribeURL(
        urlString: String,
        persistResult: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let inputURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Apple Podcasts links are their own lane: resolve via the iTunes
        // lookup API to an enclosure + episode metadata, fetch the audio with
        // the native streaming downloader, then transcribe. Everything else
        // (YouTube + generic media URLs) keeps the yt-dlp `.youtube` lineage.
        if PodcastURLValidator.isApplePodcastsURL(inputURL) {
            return try await transcribePodcastURL(
                inputURL,
                persistResult: persistResult,
                onProgress: onProgress
            )
        }

        let operation = TranscriptionOperationContext(
            source: .youtube,
            inputKind: YouTubeURLValidator.isYouTubeURL(inputURL) ? .youtube : .media,
            mediaExtension: nil,
            fileSizeBucket: nil,
            urlPlatform: TelemetryURLPlatform(MediaPlatform.recognize(inputURL))
        )
        return try await Observability.withOperationContext(operation.operationContext) {
            guard youtubeDownloader != nil else {
                sendTranscriptionOperation(
                    operation,
                    outcome: .unavailable,
                    stage: .download,
                    errorType: Self.errorType(for: YouTubeDownloadError.ytDlpNotFound)
                )
                throw YouTubeDownloadError.ytDlpNotFound
            }
            try await assertCanTranscribeOrEmitPreflight(operation)
            return try await downloadAndTranscribeResolvedMedia(
                downloadURL: inputURL,
                metadataOverride: nil,
                sourceURL: inputURL,
                telemetrySource: .youtube,
                sourceType: .youtube,
                isPodcast: false,
                operation: operation,
                persistResult: persistResult,
                onProgress: onProgress
            )
        }
    }

    /// Transcribe an Apple Podcasts page URL: iTunes-lookup resolve → native
    /// enclosure fetch → local STT.
    private func transcribePodcastURL(
        _ inputURL: String,
        persistResult: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let operation = Self.podcastOperationContext()
        return try await Observability.withOperationContext(operation.operationContext) {
            guard let resolver = podcastResolver else {
                sendTranscriptionOperation(
                    operation,
                    outcome: .unavailable,
                    stage: .download,
                    errorType: Self.errorType(for: PodcastResolveError.lookupFailed("resolver unavailable"))
                )
                throw PodcastResolveError.lookupFailed("Podcast resolver unavailable")
            }
            try await assertCanTranscribeOrEmitPreflight(operation)

            let resolved: ResolvedPodcastEpisode
            do {
                resolved = try await resolver.resolve(url: inputURL)
            } catch {
                emitPodcastResolveFailure(operation, error: error)
                throw error
            }

            return try await downloadAndTranscribeResolvedMedia(
                downloadURL: resolved.audioURL,
                metadataOverride: ResolvedMediaMetadata(podcast: resolved),
                sourceURL: inputURL,
                telemetrySource: .podcast,
                sourceType: .podcast,
                isPodcast: true,
                operation: operation,
                persistResult: persistResult,
                onProgress: onProgress
            )
        }
    }

    public func transcribePodcastQuery(
        query: String,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        try await transcribePodcastQuery(query: query, persistResult: true, onProgress: onProgress)
    }

    public func transcribePodcastQueryTransient(
        query: String,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        try await transcribePodcastQuery(query: query, persistResult: false, onProgress: onProgress)
    }

    /// Transcribe a freetext podcast query ("Lex Fridman episode 400"): iTunes
    /// search → RSS feed parse → episode select → native fetch → local STT.
    private func transcribePodcastQuery(
        query: String,
        persistResult: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let operation = Self.podcastOperationContext()
        return try await Observability.withOperationContext(operation.operationContext) {
            guard let searchResolver = podcastSearchResolver else {
                sendTranscriptionOperation(
                    operation,
                    outcome: .unavailable,
                    stage: .download,
                    errorType: Self.errorType(for: PodcastSearchError.requestFailed("resolver unavailable"))
                )
                throw PodcastSearchError.requestFailed("Podcast search resolver unavailable")
            }
            try await assertCanTranscribeOrEmitPreflight(operation)

            let resolved: ResolvedPodcastEpisode
            do {
                resolved = try await searchResolver.resolve(query: query)
            } catch {
                emitPodcastResolveFailure(operation, error: error)
                throw error
            }

            return try await downloadAndTranscribeResolvedMedia(
                downloadURL: resolved.audioURL,
                metadataOverride: ResolvedMediaMetadata(podcast: resolved),
                sourceURL: resolved.audioURL,
                telemetrySource: .podcast,
                sourceType: .podcast,
                isPodcast: true,
                operation: operation,
                persistResult: persistResult,
                onProgress: onProgress
            )
        }
    }

    private static func podcastOperationContext() -> TranscriptionOperationContext {
        TranscriptionOperationContext(
            source: .podcast,
            inputKind: .podcast,
            mediaExtension: nil,
            fileSizeBucket: nil,
            urlPlatform: .applePodcasts
        )
    }

    private func emitPodcastResolveFailure(_ operation: TranscriptionOperationContext, error: Error) {
        if error is CancellationError {
            Telemetry.send(.transcriptionCancelled(source: .podcast, audioDurationSeconds: nil, stage: .download))
            sendTranscriptionOperation(operation, outcome: .cancelled, stage: .download)
        } else {
            Telemetry.send(.transcriptionFailed(
                source: .podcast,
                stage: .download,
                errorType: Self.errorType(for: error),
                errorDetail: TelemetryErrorClassifier.errorDetail(error)
            ))
            sendTranscriptionOperation(
                operation,
                outcome: .failure,
                stage: .download,
                errorType: Self.errorType(for: error)
            )
        }
    }

    /// Shared body: download the resolved media (native streaming fetch for
    /// podcasts, yt-dlp for YouTube/generic media), persist, and transcribe.
    private func downloadAndTranscribeResolvedMedia(
        downloadURL: String,
        metadataOverride: ResolvedMediaMetadata?,
        sourceURL: String,
        telemetrySource: TelemetryTranscriptionSource,
        sourceType: Transcription.SourceType,
        isPodcast: Bool,
        operation: TranscriptionOperationContext,
        persistResult: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        var unownedDownloadedAudioURL: URL?
        defer {
            if let unownedDownloadedAudioURL {
                try? FileManager.default.removeItem(at: unownedDownloadedAudioURL)
            }
        }

        let downloadResult: YouTubeDownloader.DownloadResult
        do {
            onProgress?(.downloading(percent: 0))
            if isPodcast {
                guard let fetcher = podcastAudioFetcher else {
                    throw PodcastAudioFetchError.requestFailed("Podcast audio fetcher unavailable")
                }
                let fetchedURL = try await fetcher.fetch(
                    audioURL: downloadURL,
                    suggestedName: metadataOverride?.title
                ) { percent in
                    onProgress?(.downloading(percent: percent))
                }
                downloadResult = YouTubeDownloader.DownloadResult(
                    audioFileURL: fetchedURL,
                    title: metadataOverride?.title ?? "Untitled",
                    durationSeconds: metadataOverride?.durationSeconds,
                    channelName: metadataOverride?.channelName,
                    thumbnailURL: metadataOverride?.thumbnailURL,
                    videoDescription: metadataOverride?.description
                )
            } else {
                guard let downloader = youtubeDownloader else {
                    throw YouTubeDownloadError.ytDlpNotFound
                }
                downloadResult = try await downloader.download(url: downloadURL) { percent in
                    onProgress?(.downloading(percent: percent))
                }
            }
        } catch {
            if error is CancellationError {
                Telemetry.send(.transcriptionCancelled(source: telemetrySource, audioDurationSeconds: nil, stage: .download))
                sendTranscriptionOperation(operation, outcome: .cancelled, stage: .download)
            } else {
                Telemetry.send(.transcriptionFailed(
                    source: telemetrySource,
                    stage: .download,
                    errorType: Self.errorType(for: error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
                sendTranscriptionOperation(operation, outcome: .failure, stage: .download, errorType: Self.errorType(for: error))
            }
            throw error
        }
        unownedDownloadedAudioURL = downloadResult.audioFileURL
        onProgress?(.downloading(percent: 100))
        // Prefer the resolver duration whichever is positive; the resolver wins
        // for podcasts (a raw enclosure URL rarely advertises its length).
        let resolvedDurationSeconds = [metadataOverride?.durationSeconds, downloadResult.durationSeconds]
            .compactMap { $0 }
            .first { $0 > 0 }
        let audioDurationSeconds = resolvedDurationSeconds.map(Double.init)
        do {
            try Task.checkCancellation()
        } catch {
            Telemetry.send(.transcriptionCancelled(source: telemetrySource, audioDurationSeconds: audioDurationSeconds, stage: .download))
            sendTranscriptionOperation(operation, outcome: .cancelled, stage: .download, audioDurationSeconds: audioDurationSeconds)
            throw error
        }
        let keepDownloadedAudio = shouldKeepDownloadedAudio() && persistResult
        let embeddedMetadata = await mediaMetadataExtractor.metadata(for: downloadResult.audioFileURL)
        let title = Self.firstNonEmpty(
            metadataOverride?.title,
            downloadResult.title == "Untitled" ? nil : downloadResult.title,
            embeddedMetadata.title,
            downloadResult.title
        ) ?? "Untitled"
        let durationMs = resolvedDurationSeconds.map { $0 * 1000 } ?? embeddedMetadata.durationMs
        let channelName = Self.firstNonEmpty(metadataOverride?.channelName, downloadResult.channelName, embeddedMetadata.author)
        let videoDescription = Self.firstNonEmpty(metadataOverride?.description, downloadResult.videoDescription, embeddedMetadata.description)
        let thumbnailURL = Self.firstNonEmpty(metadataOverride?.thumbnailURL, downloadResult.thumbnailURL)
        let artifactMetadata = YouTubeAudioArtifactMetadata(
            title: title,
            artist: channelName,
            description: videoDescription,
            thumbnailURL: thumbnailURL
        )

        var transcription = Transcription(
            fileName: title,
            filePath: keepDownloadedAudio ? downloadResult.audioFileURL.path : nil,
            durationMs: durationMs,
            language: nil,
            status: .processing,
            sourceURL: sourceURL,
            thumbnailURL: thumbnailURL,
            channelName: channelName,
            videoDescription: videoDescription,
            sourceType: sourceType
        )
        if persistResult {
            do {
                try transcriptionRepo.save(transcription)
            } catch {
                sendTranscriptionOperation(operation, outcome: .failure, stage: .persistence, audioDurationSeconds: audioDurationSeconds, errorType: Self.errorType(for: error))
                throw error
            }
        }
        if persistResult, thumbnailURL == nil {
            await cacheEmbeddedArtworkIfPresent(embeddedMetadata, for: transcription.id)
        }
        if keepDownloadedAudio {
            unownedDownloadedAudioURL = nil
        }
        Telemetry.send(.transcriptionStarted(source: telemetrySource, audioDurationSeconds: audioDurationSeconds))

        // Cache remote artwork locally (non-blocking) — YouTube thumbnail or
        // Apple Podcasts episode artwork.
        if persistResult, let thumbURL = thumbnailURL {
            let transcriptionId = transcription.id
            let logger = self.logger
            let thumbnailCache = self.thumbnailCache
            Task.detached(priority: .utility) {
                do {
                    _ = try await thumbnailCache.downloadThumbnail(from: thumbURL, for: transcriptionId)
                } catch {
                    logger.error("transcription_thumbnail_download_failed id=\(transcriptionId, privacy: .public) error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
                }
            }
        }

        onProgress?(.transcribing(percent: 0))
        if !keepDownloadedAudio {
            unownedDownloadedAudioURL = nil
        }
        let completed = try await transcribeAudio(
            fileURL: downloadResult.audioFileURL,
            source: telemetrySource,
            sttJob: .fileTranscription,
            transcription: &transcription,
            operation: operation,
            tempFiles: [downloadResult.audioFileURL],
            cleanUpDownloadedFiles: !keepDownloadedAudio,
            persistResult: persistResult,
            onProgress: onProgress
        )

        // Issue #237: "Best available" yt-dlp downloads (Opus-in-WebM) measurably
        // improve Parakeet WER, but AVFoundation has no WebM/Opus decoder, so the
        // saved file silently fails on the in-app audio scrubber. Transcode the
        // retained file to .m4a off the main return so the scrubber can play it.
        // Podcast enclosures are normally already playable, so this is a no-op
        // for them, but harmless.
        if keepDownloadedAudio,
           let storedPath = completed.filePath,
           YouTubeAudioPlaybackConverter.needsConversion(forPath: storedPath) {
            schedulePlaybackConversion(
                transcriptionId: completed.id,
                inputPath: storedPath,
                metadata: artifactMetadata
            )
        }

        return completed
    }

    /// Fire-and-forget post-STT transcode of an unplayable YouTube audio
    /// file into AVPlayer-compatible `.m4a`. Failures are non-fatal — the
    /// transcript is already saved, the worst case is the audio scrubber
    /// stays inert for that file (current behavior pre-fix).
    ///
    /// Source-file deletion happens only after the DB has been updated to
    /// point at the new `.m4a`. The reverse order would orphan the m4a if
    /// the DB write failed — the row would still reference a deleted webm
    /// and the audio scrubber would be empty.
    private func schedulePlaybackConversion(
        transcriptionId: UUID,
        inputPath: String,
        metadata: YouTubeAudioArtifactMetadata?
    ) {
        let converter = playbackConverter
        let repo = transcriptionRepo
        let logger = self.logger
        Task.detached(priority: .utility) {
            do {
                let newPath = try await converter.convertToPlayableM4AIfNeeded(
                    inputPath: inputPath,
                    metadata: metadata
                )
                guard newPath != inputPath else { return }
                try repo.updateFilePath(id: transcriptionId, filePath: newPath)
                try? FileManager.default.removeItem(atPath: inputPath)
                logger.info("youtube_audio_postprocessed id=\(transcriptionId, privacy: .public)")
            } catch {
                logger.error("youtube_audio_postprocess_failed id=\(transcriptionId, privacy: .public) error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Private

    private func meetingFileSize(for recording: MeetingRecordingOutput) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: recording.mixedAudioURL.path)[.size] as? Int)
            .flatMap { $0 }
    }

    private func meetingOperationContext(for recording: MeetingRecordingOutput) -> TranscriptionOperationContext {
        let fileSize = meetingFileSize(for: recording)
        return TranscriptionOperationContext(
            source: .meeting,
            inputKind: .meeting,
            mediaExtension: Observability.mediaExtension(for: recording.mixedAudioURL),
            fileSizeBucket: Observability.fileSizeBucket(bytes: fileSize)
        )
    }

    private func makeMeetingTranscriptionStub(recording: MeetingRecordingOutput) -> Transcription {
        Transcription(
            fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path,
            meetingArtifactFolderPath: recording.folderURL.path,
            fileSizeBytes: meetingFileSize(for: recording),
            durationMs: Int((recording.durationSeconds * 1000).rounded()),
            language: nil,
            status: .processing,
            sourceType: .meeting,
            userNotes: recording.userNotes,
            engine: recording.speechEngine.engine.rawValue
        )
    }

    private func transcribeMeetingAudio(
        recording: MeetingRecordingOutput,
        transcription: inout Transcription,
        operation: TranscriptionOperationContext,
        persistFailureStatus: Bool = true,
        speechEngineOverride: SpeechEngineSelection? = nil,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let processingStartedAt = Date()
        var lifecycleStage: TelemetryTranscriptionStage = .audioConversion
        let diarizationRequested = diarizationService != nil && shouldDiarize() && recording.sourceAlignment.system != nil
        var temporaryWavURLs: [URL] = []
        var sourceWavURLs: [AudioSource: URL] = [:]
        defer {
            for wavURL in temporaryWavURLs {
                try? FileManager.default.removeItem(at: wavURL)
            }
        }

        do {
            let sourceResults = try await transcribeMeetingSources(
                recording: recording,
                lifecycleStage: &lifecycleStage,
                temporaryWavURLs: &temporaryWavURLs,
                sourceWavURLs: &sourceWavURLs,
                speechEngineOverride: speechEngineOverride,
                onProgress: onProgress
            )

            let systemDiarization = try await diarizeMeetingSystemIfNeeded(
                recording: recording,
                sourceWavURLs: sourceWavURLs,
                requested: diarizationRequested,
                lifecycleStage: &lifecycleStage,
                onProgress: onProgress
            )

            let finalized = MeetingTranscriptFinalizer.finalize(
                sourceTranscripts: sourceResults,
                systemDiarization: systemDiarization
            )

            // Apply the user's Vocabulary corrections to the meeting transcript.
            // Meetings otherwise never run custom words — the deterministic
            // pipeline only touches dictation/file transcripts — so names the
            // user has already corrected elsewhere would still come through raw
            // here (issue #550). Intentionally always-on, not gated on the
            // Raw/Clean dictation mode: the corrections drive the
            // speaker-segmented view and the word-timestamp exports, and the
            // default processing mode is `.raw`. `completeTranscription` below
            // still receives the *uncorrected* `finalized.rawTranscript`, so its
            // Clean-mode pass derives `cleanTranscript` without double-applying.
            let corrected = MeetingTranscriptVocabularyApplier.apply(
                rawTranscript: finalized.rawTranscript,
                words: finalized.words,
                customWords: fetchMeetingVocabulary()
            )
            transcription.rawTranscript = corrected.rawTranscript
            transcription.wordTimestamps = corrected.words
            transcription.language = Self.commonDetectedLanguage(from: sourceResults) ?? transcription.language
            // Both meeting source transcripts (mic + system) run through the
            // same `SpeechEngineSelection`, so taking the first source's
            // engine attribution is authoritative for the merged transcript.
            if let engineSource = sourceResults.first {
                transcription.engine = engineSource.result.engine.rawValue
                transcription.engineVariant = engineSource.result.engineVariant
            }
            transcription.durationMs = max(
                Int((recording.durationSeconds * 1000).rounded()),
                finalized.durationMs ?? 0
            )
            transcription.speakers = finalized.speakers
            transcription.speakerCount = finalized.speakers.isEmpty ? nil : finalized.speakers.count
            transcription.diarizationSegments = finalized.diarizationSegments.isEmpty ? nil : finalized.diarizationSegments

            lifecycleStage = .postProcessing
            let completed = try await completeTranscription(
                source: .meeting,
                transcription: &transcription,
                operation: operation,
                rawText: finalized.rawTranscript,
                processingStartedAt: processingStartedAt,
                diarizationRequested: diarizationRequested,
                diarizationApplied: systemDiarization != nil
            )

            return completed
        } catch {
            let audioDurationSeconds = transcription.durationMs.map { Double($0) / 1000.0 } ?? recording.durationSeconds
            if error is CancellationError {
                Telemetry.send(.transcriptionCancelled(
                    source: .meeting,
                    audioDurationSeconds: audioDurationSeconds,
                    stage: lifecycleStage
                ))
                sendTranscriptionOperation(
                    operation,
                    outcome: .cancelled,
                    stage: lifecycleStage,
                    audioDurationSeconds: audioDurationSeconds,
                    diarizationRequested: diarizationRequested,
                    speechEngine: transcription.engine,
                    engineVariant: transcription.engineVariant
                )
            } else {
                Telemetry.send(.transcriptionFailed(
                    source: .meeting,
                    stage: lifecycleStage,
                    errorType: Self.errorType(for: error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
                sendTranscriptionOperation(
                    operation,
                    outcome: .failure,
                    stage: lifecycleStage,
                    audioDurationSeconds: audioDurationSeconds,
                    diarizationRequested: diarizationRequested,
                    speechEngine: transcription.engine,
                    engineVariant: transcription.engineVariant,
                    errorType: Self.errorType(for: error)
                )
            }

            if persistFailureStatus {
                let txID = transcription.id
                if error is CancellationError {
                    do {
                        try transcriptionRepo.updateStatus(
                            id: txID,
                            status: .cancelled,
                            errorMessage: nil
                        )
                    } catch let dbError {
                        logger.error("failed_to_update_cancelled_status id=\(txID) dbError=\(dbError.localizedDescription, privacy: .public)")
                    }
                } else {
                    do {
                        try transcriptionRepo.updateStatus(
                            id: txID,
                            status: .error,
                            errorMessage: error.localizedDescription
                        )
                    } catch let dbError {
                        logger.error("failed_to_update_error_status id=\(txID) dbError=\(dbError.localizedDescription, privacy: .public)")
                    }
                }
            }
            throw error
        }
    }

    private func transcribeMeetingSources(
        recording: MeetingRecordingOutput,
        lifecycleStage: inout TelemetryTranscriptionStage,
        temporaryWavURLs: inout [URL],
        sourceWavURLs: inout [AudioSource: URL],
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [MeetingTranscriptFinalizer.SourceTranscript] {
        var outputs: [MeetingTranscriptFinalizer.SourceTranscript] = []
        let activeSources = [AudioSource.microphone, .system].filter { recording.sourceAlignment.track(for: $0) != nil }
        let speechEngine = speechEngineOverride ?? (recording.speechEngineWasCaptured ? recording.speechEngine : nil)

        for (index, source) in activeSources.enumerated() {
            let fileURL = meetingAudioURL(for: source, recording: recording)
            lifecycleStage = .audioConversion
            onProgress?(.converting)
            let wavURL = try await audioProcessor.convert(fileURL: fileURL)
            temporaryWavURLs.append(wavURL)
            sourceWavURLs[source] = wavURL

            lifecycleStage = .stt
            onProgress?(.transcribing(percent: Int((Double(index) / Double(max(activeSources.count, 1))) * 100)))
            let result = try await transcribeSpeech(
                audioPath: wavURL.path,
                job: .meetingFinalize,
                speechEngine: speechEngine,
                onProgress: meetingSourceProgressMapper(
                    sourceIndex: index,
                    sourceCount: activeSources.count,
                    onProgress: onProgress
                )
            )

            outputs.append(
                .init(
                    source: source,
                    result: result,
                    startOffsetMs: recording.sourceAlignment.track(for: source)?.startOffsetMs ?? 0
                )
            )
        }

        return outputs
    }

    private func diarizeMeetingSystemIfNeeded(
        recording: MeetingRecordingOutput,
        sourceWavURLs: [AudioSource: URL],
        requested: Bool,
        lifecycleStage: inout TelemetryTranscriptionStage,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> MeetingTranscriptFinalizer.SystemDiarization? {
        guard requested, let diarizationService else { return nil }
        guard let systemTrack = recording.sourceAlignment.system else { return nil }
        guard let systemWavURL = sourceWavURLs[.system] else { return nil }

        lifecycleStage = .diarization
        do {
            onProgress?(.identifyingSpeakers)
            Telemetry.send(.diarizationStarted(source: .meeting))
            let diarStartedAt = Date()
            let diarResult = try await diarizationService.diarize(audioURL: systemWavURL)
            let diarDuration = Date().timeIntervalSince(diarStartedAt)
            Telemetry.send(.diarizationCompleted(
                source: .meeting,
                speakerCount: diarResult.speakerCount,
                durationSeconds: diarDuration
            ))

            guard !diarResult.segments.isEmpty else { return nil }

            let mappedSpeakers = diarResult.speakers.enumerated().map { index, speaker in
                SpeakerInfo(
                    id: "\(AudioSource.system.rawValue):\(speaker.id)",
                    label: "\(AudioSource.system.displayLabel) \(index + 1)"
                )
            }
            let speakerIDMap = Dictionary(uniqueKeysWithValues: zip(
                diarResult.speakers.map(\.id),
                mappedSpeakers.map(\.id)
            ))
            let mappedSegments = diarResult.segments.map { segment in
                SpeakerSegment(
                    speakerId: speakerIDMap[segment.speakerId] ?? "\(AudioSource.system.rawValue):\(segment.speakerId)",
                    startMs: segment.startMs + systemTrack.startOffsetMs,
                    endMs: segment.endMs + systemTrack.startOffsetMs
                )
            }

            return MeetingTranscriptFinalizer.SystemDiarization(
                speakers: mappedSpeakers,
                segments: mappedSegments
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("meeting_system_diarization_failed error=\(error.localizedDescription, privacy: .public)")
            Telemetry.send(.diarizationFailed(
                source: .meeting,
                errorType: String(describing: type(of: error)),
                errorDetail: TelemetryErrorClassifier.errorDetail(error)
            ))
            return nil
        }
    }

    private func meetingAudioURL(for source: AudioSource, recording: MeetingRecordingOutput) -> URL {
        switch source {
        case .microphone:
            return recording.microphoneAudioURL
        case .system:
            return recording.systemAudioURL
        }
    }

    private func meetingSourceProgressMapper(
        sourceIndex: Int,
        sourceCount: Int,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) -> (@Sendable (Int, Int) -> Void)? {
        guard let onProgress else { return nil }
        return { current, total in
            let phaseSpan = max(1, sourceCount)
            let sourceFraction = total > 0 ? Double(current) / Double(total) : 0
            let overall = (Double(sourceIndex) + sourceFraction) / Double(phaseSpan)
            let percent = min(Int((overall * 100).rounded()), 99)
            onProgress(.transcribing(percent: percent))
        }
    }

    private func transcribeSpeech(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection?,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        if let speechEngine {
            guard let routed = sttTranscriber as? any SpeechEngineRoutedTranscribing else {
                throw STTError.engineStartFailed(
                    "Pinned \(speechEngine.engine.rawValue) speech engine cannot be honored by this transcriber."
                )
            }
            return try await routed.transcribe(
                audioPath: audioPath,
                job: job,
                speechEngine: speechEngine,
                onProgress: onProgress
            )
        }

        return try await sttTranscriber.transcribe(
            audioPath: audioPath,
            job: job,
            onProgress: onProgress
        )
    }

    private func transcribeAudio(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        sttJob: STTJobKind,
        transcription: inout Transcription,
        operation: TranscriptionOperationContext,
        tempFiles: [URL],
        cleanUpDownloadedFiles: Bool = true,
        persistResult: Bool = true,
        persistFailureStatus: Bool = true,
        speechEngine: SpeechEngineSelection? = nil,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        var wavURL: URL?
        let processingStartedAt = Date()
        var lifecycleStage: TelemetryTranscriptionStage = .audioConversion
        let diarizationRequested = diarizationService != nil && shouldDiarize()
        do {
            onProgress?(.converting)
            wavURL = try await audioProcessor.convert(fileURL: fileURL)

            guard let wavURL else {
                throw AudioProcessorError.conversionFailed("Failed to produce WAV output")
            }

            onProgress?(.transcribing(percent: 0))
            lifecycleStage = .stt
            let sttProgress: (@Sendable (Int, Int) -> Void)? = onProgress.map { callback in
                { @Sendable current, total in
                    let pct = total > 0 ? Int(Double(current) / Double(total) * 100) : 0
                    callback(.transcribing(percent: min(pct, 99)))
                }
            }
            let result = try await transcribeSpeech(
                audioPath: wavURL.path,
                job: sttJob,
                speechEngine: speechEngine,
                onProgress: sttProgress
            )

            let words = result.words.map { word in
                WordTimestamp(
                    word: word.word,
                    startMs: word.startMs,
                    endMs: word.endMs,
                    confidence: word.confidence
                )
            }

            transcription.rawTranscript = result.text
            transcription.wordTimestamps = words
            transcription.language = SpeechEnginePreference.normalizeKnownLanguage(result.language) ?? transcription.language
            transcription.engine = result.engine.rawValue
            transcription.engineVariant = result.engineVariant
            if let speechDurationMs = words.map(\.endMs).max() {
                transcription.durationMs = max(transcription.durationMs ?? 0, speechDurationMs)
            }

            let diarizationApplied: Bool
            if let diarizationService, shouldDiarize() {
                lifecycleStage = .diarization
                do {
                    onProgress?(.identifyingSpeakers)
                    Telemetry.send(.diarizationStarted(source: source))
                    let diarStartedAt = Date()
                    let diarResult = try await diarizationService.diarize(audioURL: wavURL)
                    let diarDuration = Date().timeIntervalSince(diarStartedAt)
                    if !diarResult.segments.isEmpty {
                        let mergedWords = SpeakerMerger.mergeWordTimestampsWithSpeakers(
                            words: words,
                            segments: diarResult.segments
                        )
                        transcription.wordTimestamps = mergedWords
                        transcription.speakerCount = diarResult.speakerCount
                        transcription.speakers = diarResult.speakers
                        transcription.diarizationSegments = diarResult.segments.map {
                            DiarizationSegmentRecord(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs)
                        }
                    }
                    diarizationApplied = !diarResult.segments.isEmpty
                    Telemetry.send(.diarizationCompleted(
                        source: source,
                        speakerCount: diarResult.speakerCount,
                        durationSeconds: diarDuration
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    diarizationApplied = false
                    logger.error("diarization_failed error=\(error.localizedDescription, privacy: .public)")
                    Telemetry.send(.diarizationFailed(
                        source: source,
                        errorType: String(describing: type(of: error)),
                        errorDetail: TelemetryErrorClassifier.errorDetail(error)
                    ))
                }
            } else {
                diarizationApplied = false
            }

            lifecycleStage = .postProcessing
            let completed = try await completeTranscription(
                source: source,
                transcription: &transcription,
                operation: operation,
                rawText: result.text,
                processingStartedAt: processingStartedAt,
                diarizationRequested: diarizationRequested,
                diarizationApplied: diarizationApplied,
                persistResult: persistResult
            )

            try? FileManager.default.removeItem(at: wavURL)
            if cleanUpDownloadedFiles {
                for tempFile in tempFiles {
                    try? FileManager.default.removeItem(at: tempFile)
                }
            }

            return completed
        } catch {
            if let wavURL { try? FileManager.default.removeItem(at: wavURL) }
            if cleanUpDownloadedFiles {
                for tempFile in tempFiles {
                    try? FileManager.default.removeItem(at: tempFile)
                }
            }

            let audioDurationSeconds = transcription.durationMs.map { Double($0) / 1000.0 }
            if error is CancellationError {
                Telemetry.send(.transcriptionCancelled(
                    source: source,
                    audioDurationSeconds: audioDurationSeconds,
                    stage: lifecycleStage
                ))
                sendTranscriptionOperation(
                    operation,
                    outcome: .cancelled,
                    stage: lifecycleStage,
                    audioDurationSeconds: audioDurationSeconds,
                    diarizationRequested: diarizationRequested,
                    speechEngine: transcription.engine,
                    engineVariant: transcription.engineVariant
                )
            } else {
                Telemetry.send(.transcriptionFailed(
                    source: source,
                    stage: lifecycleStage,
                    errorType: Self.errorType(for: error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
                sendTranscriptionOperation(
                    operation,
                    outcome: .failure,
                    stage: lifecycleStage,
                    audioDurationSeconds: audioDurationSeconds,
                    diarizationRequested: diarizationRequested,
                    speechEngine: transcription.engine,
                    engineVariant: transcription.engineVariant,
                    errorType: Self.errorType(for: error)
                )
            }

            if persistResult && persistFailureStatus {
                let txID = transcription.id
                if error is CancellationError {
                    do {
                        try transcriptionRepo.updateStatus(
                            id: txID,
                            status: .cancelled,
                            errorMessage: nil
                        )
                    } catch let dbError {
                        logger.error("failed_to_update_cancelled_status id=\(txID) dbError=\(dbError.localizedDescription, privacy: .public)")
                    }
                } else {
                    do {
                        try transcriptionRepo.updateStatus(
                            id: txID,
                            status: .error,
                            errorMessage: error.localizedDescription
                        )
                    } catch let dbError {
                        logger.error("failed_to_update_error_status id=\(txID) dbError=\(dbError.localizedDescription, privacy: .public)")
                    }
                }
            }
            throw error
        }
    }

    private func makeRetranscriptionRecord(from original: Transcription) -> Transcription {
        var transcription = original
        transcription.durationMs = nil
        transcription.rawTranscript = nil
        transcription.cleanTranscript = nil
        transcription.wordTimestamps = nil
        transcription.language = nil
        transcription.speakerCount = nil
        transcription.speakers = nil
        transcription.diarizationSegments = nil
        transcription.status = .processing
        transcription.errorMessage = nil
        transcription.exportPath = nil
        transcription.engine = nil
        transcription.engineVariant = nil
        transcription.isTranscriptEdited = false
        transcription.updatedAt = Date()
        return transcription
    }

    private func cacheEmbeddedArtworkIfPresent(_ metadata: MediaMetadata, for transcriptionID: UUID) async {
        guard let artworkData = metadata.artworkData else { return }
        let thumbnailCache = self.thumbnailCache
        do {
            _ = try await Task.detached(priority: .utility) {
                try thumbnailCache.cacheThumbnailData(artworkData, for: transcriptionID)
            }.value
        } catch {
            logger.error("transcription_embedded_thumbnail_cache_failed id=\(transcriptionID, privacy: .public) error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
        }
    }

    private static func commonDetectedLanguage(
        from sourceResults: [MeetingTranscriptFinalizer.SourceTranscript]
    ) -> String? {
        let languages = Set(sourceResults.compactMap { source in
            SpeechEnginePreference.normalizeKnownLanguage(source.result.language)
        })
        return languages.count == 1 ? languages.first : nil
    }

    /// Enabled custom words for meeting transcript correction.
    ///
    /// Unlike `completeTranscription`'s fetch this is not gated on the Raw/Clean
    /// processing mode — meeting corrections are always applied (see the call
    /// site in the meeting finalize path). Failures degrade to no corrections
    /// rather than failing the transcription.
    private func fetchMeetingVocabulary() -> [CustomWord] {
        do {
            return try customWordRepo?.fetchEnabled() ?? []
        } catch {
            logger.error("meeting_custom_words_fetch_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    private func completeTranscription(
        source: TelemetryTranscriptionSource,
        transcription: inout Transcription,
        operation: TranscriptionOperationContext,
        rawText: String,
        processingStartedAt: Date,
        diarizationRequested: Bool,
        diarizationApplied: Bool,
        persistResult: Bool = true
    ) async throws -> Transcription {
        let mode = processingMode()
        var customWords: [CustomWord] = []
        var snippets: [TextSnippet] = []
        if mode.usesDeterministicPipeline {
            do { customWords = try customWordRepo?.fetchEnabled() ?? [] }
            catch { logger.error("transcription_custom_words_fetch_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)") }
            do { snippets = try snippetRepo?.fetchEnabled() ?? [] }
            catch { logger.error("transcription_snippets_fetch_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)") }
        }

        let refinement = await textRefinementService.refine(
            rawText: rawText,
            mode: mode,
            customWords: customWords,
            snippets: snippets
        )
        let baseText = refinement.text ?? rawText
        let transcriptFormatter = TranscriptFormatter(
            llmService: llmService,
            shouldUseAIFormatter: shouldUseAIFormatter,
            logger: logger
        )
        let promptTemplateProvider = aiFormatterPromptTemplate
        let formatterOutcome = try await transcriptFormatter.format(
            baseText,
            runSource: persistResult ? LLMRunSource(transcriptionId: transcription.id) : nil,
            lane: .transcription,
            resolvePrompt: { (promptTemplateProvider(), nil) }
        )
        let formattedTranscript = formatterOutcome.text
        transcription.cleanTranscript = formattedTranscript ?? refinement.text

        if persistResult, !refinement.expandedSnippetIDs.isEmpty {
            try? snippetRepo?.incrementUseCount(ids: refinement.expandedSnippetIDs)
        }

        let derivationSource = transcription.cleanTranscript ?? transcription.rawTranscript
        transcription.derivedTitle = TitleDeriver.derive(from: derivationSource) ?? ""
        transcription.derivedSnippet = SnippetDeriver.derive(
            from: derivationSource,
            excluding: transcription.derivedTitle
        ) ?? ""

        if persistResult, source == .meeting,
           let generatedTitle = try await generateMeetingTitleIfNeeded(
               transcriptText: derivationSource,
               currentTitle: transcription.fileName
           ) {
            transcription.fileName = generatedTitle
            transcription.derivedTitle = generatedTitle
        }

        transcription.status = .completed
        transcription.updatedAt = Date()
        if persistResult {
            try transcriptionRepo.save(transcription)
            await llmRunRecorder.record(formatterOutcome.run)
        }

        if persistResult, source == .meeting {
            await materializeMeetingArtifactIfPossible(transcription)
        }

        let outputText = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        let wordCount = outputText.split(whereSeparator: \.isWhitespace).count
        let audioDurationSeconds = transcription.durationMs.map { Double($0) / 1000.0 }
        let processingSeconds = Date().timeIntervalSince(processingStartedAt)
        Telemetry.send(.transcriptionCompleted(
            source: source,
            audioDurationSeconds: audioDurationSeconds,
            processingSeconds: processingSeconds,
            wordCount: wordCount,
            speakerCount: transcription.speakerCount,
            diarizationRequested: diarizationRequested,
            diarizationApplied: diarizationApplied,
            speechEngine: transcription.engine,
            engineVariant: transcription.engineVariant,
            language: transcription.language
        ))
        sendTranscriptionOperation(
            operation,
            outcome: .success,
            stage: .postProcessing,
            audioDurationSeconds: audioDurationSeconds,
            processingSeconds: processingSeconds,
            wordCount: wordCount,
            speakerCount: transcription.speakerCount,
            diarizationRequested: diarizationRequested,
            diarizationApplied: diarizationApplied,
            speechEngine: transcription.engine,
            engineVariant: transcription.engineVariant,
            language: transcription.language
        )

        return transcription
    }

    private func generateMeetingTitleIfNeeded(
        transcriptText: String?,
        currentTitle: String
    ) async throws -> String? {
        guard let transcriptText else { return nil }
        let generator = MeetingTitleGenerator(
            llmService: llmService,
            shouldGenerate: shouldAutoGenerateMeetingTitles,
            logger: logger
        )
        return try await generator.generateTitle(
            transcript: transcriptText,
            currentTitle: currentTitle
        )
    }

    private func materializeMeetingArtifactIfPossible(_ transcription: Transcription) async {
        guard let meetingArtifactStore else { return }
        do {
            let promptResults = try promptResultRepo?.fetchAll(transcriptionId: transcription.id) ?? []
            let artifact = try await meetingArtifactStore.materialize(
                transcription: transcription,
                promptResults: promptResults
            )
            runMeetingAutomationHookIfConfigured(transcription: transcription, artifact: artifact)
        } catch {
            logger.warning("meeting_artifact_materialize_failed id=\(transcription.id.uuidString, privacy: .public) error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
        }
    }

    private func runMeetingAutomationHookIfConfigured(
        transcription: Transcription,
        artifact: MeetingArtifactSnapshot
    ) {
        guard let meetingAutomationHookRunner else { return }
        Task.detached(priority: .utility) {
            _ = await meetingAutomationHookRunner.runCompletedMeetingHook(
                transcription: transcription,
                artifact: artifact
            )
        }
    }

    private static func errorType(for error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    private func assertCanTranscribeOrEmitPreflight(
        _ operation: TranscriptionOperationContext,
        audioDurationSeconds: Double? = nil
    ) async throws {
        do {
            if let entitlements {
                try await entitlements.assertCanTranscribe(now: Date())
            }
        } catch {
            sendTranscriptionOperation(
                operation,
                outcome: .unavailable,
                stage: .preflight,
                audioDurationSeconds: audioDurationSeconds,
                errorType: Self.errorType(for: error)
            )
            throw error
        }
    }

    private func sendTranscriptionOperation(
        _ operation: TranscriptionOperationContext,
        outcome: ObservabilityOutcome,
        stage: TelemetryTranscriptionStage?,
        audioDurationSeconds: Double? = nil,
        processingSeconds: Double? = nil,
        wordCount: Int? = nil,
        speakerCount: Int? = nil,
        diarizationRequested: Bool = false,
        diarizationApplied: Bool = false,
        speechEngine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil,
        errorType: String? = nil
    ) {
        Telemetry.send(.transcriptionOperation(
            operationID: operation.operationContext.operationID,
            operationContext: operation.operationContext,
            outcome: outcome,
            source: operation.source,
            stage: stage,
            durationSeconds: Observability.durationSeconds(since: operation.operationContext.startedAt),
            audioDurationSeconds: audioDurationSeconds,
            processingSeconds: processingSeconds,
            wordCount: wordCount,
            speakerCount: speakerCount,
            diarizationRequested: diarizationRequested,
            diarizationApplied: diarizationApplied,
            inputKind: operation.inputKind,
            mediaExtension: operation.mediaExtension,
            fileSizeBucket: operation.fileSizeBucket,
            speechEngine: speechEngine,
            engineVariant: engineVariant,
            language: language,
            errorType: errorType,
            platform: operation.urlPlatform
        ))
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv"]

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}

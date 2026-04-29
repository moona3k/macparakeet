import Foundation
import OSLog

public protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func transcribeMeeting(
        recording: MeetingRecordingOutput,
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

    public func transcribeURL(urlString: String) async throws -> Transcription {
        try await transcribeURL(urlString: urlString, onProgress: nil)
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

    init(
        source: TelemetryTranscriptionSource,
        inputKind: ObservabilityInputKind?,
        mediaExtension: String?,
        fileSizeBucket: String?,
        operationContext: ObservabilityOperationContext = Observability.childOperationContext()
    ) {
        self.operationContext = operationContext
        self.source = source
        self.inputKind = inputKind
        self.mediaExtension = mediaExtension
        self.fileSizeBucket = fileSizeBucket
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
    private let shouldUseAIFormatter: @Sendable () -> Bool
    private let aiFormatterPromptTemplate: @Sendable () -> String
    private let shouldKeepDownloadedAudio: @Sendable () -> Bool
    private let shouldDiarize: @Sendable () -> Bool
    private let youtubeDownloader: YouTubeDownloading?
    private let diarizationService: DiarizationServiceProtocol?

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttTranscriber: STTTranscribing,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        llmService: LLMServiceProtocol? = nil,
        shouldUseAIFormatter: (@Sendable () -> Bool)? = nil,
        aiFormatterPromptTemplate: (@Sendable () -> String)? = nil,
        shouldKeepDownloadedAudio: (@Sendable () -> Bool)? = nil,
        shouldDiarize: (@Sendable () -> Bool)? = nil,
        youtubeDownloader: YouTubeDownloading? = nil,
        diarizationService: DiarizationServiceProtocol? = nil
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
        self.shouldUseAIFormatter = shouldUseAIFormatter ?? { false }
        self.aiFormatterPromptTemplate = aiFormatterPromptTemplate ?? { AIFormatter.defaultPromptTemplate }
        self.shouldKeepDownloadedAudio = shouldKeepDownloadedAudio ?? { true }
        self.shouldDiarize = shouldDiarize ?? { true }
        self.youtubeDownloader = youtubeDownloader
        self.diarizationService = diarizationService
    }

    public func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource = .file,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let sourceType: Transcription.SourceType = switch source {
        case .youtube:
            .youtube
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
            onProgress: onProgress
        )
    }

    public func transcribeMeeting(
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: recording.mixedAudioURL.path)[.size] as? Int)
            .flatMap { $0 }
        let operation = TranscriptionOperationContext(
            source: .meeting,
            inputKind: .meeting,
            mediaExtension: Observability.mediaExtension(for: recording.mixedAudioURL),
            fileSizeBucket: Observability.fileSizeBucket(bytes: fileSize)
        )

        return try await Observability.withOperationContext(operation.operationContext) {
            try await assertCanTranscribeOrEmitPreflight(
                operation,
                audioDurationSeconds: recording.durationSeconds
            )

            var transcription = Transcription(
                fileName: recording.displayName,
                filePath: recording.mixedAudioURL.path,
                fileSizeBytes: fileSize,
                status: .processing,
                sourceType: .meeting,
                userNotes: recording.userNotes
            )
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
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let fileName = displayFileName ?? storedFileURL?.lastPathComponent ?? fileURL.lastPathComponent
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
                status: .processing,
                sourceType: sourceType
            )
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
            Telemetry.send(.transcriptionStarted(source: source, audioDurationSeconds: nil))

            // Extract thumbnail from video files (non-blocking)
            if Self.isVideoFile(fileURL) {
                let transcriptionId = transcription.id
                let path = fileURL.path
                let logger = self.logger
                Task.detached(priority: .utility) {
                    do {
                        _ = try await ThumbnailCacheService.shared.extractVideoFrame(from: path, for: transcriptionId)
                    } catch {
                        logger.error("Thumbnail extraction failed for \(transcriptionId): \(error.localizedDescription, privacy: .public)")
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
                onProgress: onProgress
            )
        }
    }

    public func transcribeURL(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil) async throws -> Transcription {
        let operation = TranscriptionOperationContext(
            source: .youtube,
            inputKind: .youtube,
            mediaExtension: nil,
            fileSizeBucket: nil
        )

        return try await Observability.withOperationContext(operation.operationContext) {
            guard let downloader = youtubeDownloader else {
                sendTranscriptionOperation(
                    operation,
                    outcome: .unavailable,
                    stage: .download,
                    errorType: Self.errorType(for: YouTubeDownloadError.ytDlpNotFound)
                )
                throw YouTubeDownloadError.ytDlpNotFound
            }

            try await assertCanTranscribeOrEmitPreflight(operation)

            let downloadResult: YouTubeDownloader.DownloadResult
            do {
                onProgress?(.downloading(percent: 0))
                downloadResult = try await downloader.download(url: urlString) { percent in
                    onProgress?(.downloading(percent: percent))
                }
            } catch {
                if error is CancellationError {
                    Telemetry.send(.transcriptionCancelled(
                        source: .youtube,
                        audioDurationSeconds: nil,
                        stage: .download
                    ))
                    sendTranscriptionOperation(
                        operation,
                        outcome: .cancelled,
                        stage: .download
                    )
                } else {
                    Telemetry.send(.transcriptionFailed(
                        source: .youtube,
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
                throw error
            }
            onProgress?(.downloading(percent: 100))
            do {
                try Task.checkCancellation()
            } catch {
                Telemetry.send(.transcriptionCancelled(
                    source: .youtube,
                    audioDurationSeconds: downloadResult.durationSeconds.map(Double.init),
                    stage: .download
                ))
                sendTranscriptionOperation(
                    operation,
                    outcome: .cancelled,
                    stage: .download,
                    audioDurationSeconds: downloadResult.durationSeconds.map(Double.init)
                )
                throw error
            }
            let keepDownloadedAudio = shouldKeepDownloadedAudio()

            var transcription = Transcription(
                fileName: downloadResult.title,
                filePath: keepDownloadedAudio ? downloadResult.audioFileURL.path : nil,
                status: .processing,
                sourceURL: urlString,
                thumbnailURL: downloadResult.thumbnailURL,
                channelName: downloadResult.channelName,
                videoDescription: downloadResult.videoDescription,
                sourceType: .youtube
            )
            do {
                try transcriptionRepo.save(transcription)
            } catch {
                sendTranscriptionOperation(
                    operation,
                    outcome: .failure,
                    stage: .persistence,
                    audioDurationSeconds: downloadResult.durationSeconds.map(Double.init),
                    errorType: Self.errorType(for: error)
                )
                throw error
            }
            Telemetry.send(.transcriptionStarted(
                source: .youtube,
                audioDurationSeconds: downloadResult.durationSeconds.map(Double.init)
            ))

            // Cache YouTube thumbnail locally (non-blocking)
            if let thumbURL = downloadResult.thumbnailURL {
                let transcriptionId = transcription.id
                let logger = self.logger
                Task.detached(priority: .utility) {
                    do {
                        _ = try await ThumbnailCacheService.shared.downloadThumbnail(from: thumbURL, for: transcriptionId)
                    } catch {
                        logger.error("Thumbnail download failed for \(transcriptionId): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            onProgress?(.transcribing(percent: 0))
            return try await transcribeAudio(
                fileURL: downloadResult.audioFileURL,
                source: .youtube,
                sttJob: .fileTranscription,
                transcription: &transcription,
                operation: operation,
                tempFiles: [downloadResult.audioFileURL],
                cleanUpDownloadedFiles: !keepDownloadedAudio,
                onProgress: onProgress
            )
        }
    }

    // MARK: - Private

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

            transcription.rawTranscript = finalized.rawTranscript
            transcription.wordTimestamps = finalized.words
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
                    diarizationRequested: diarizationRequested
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
            transcription.language = result.language ?? transcription.language
            transcription.engine = result.engine.rawValue
            transcription.engineVariant = result.engineVariant
            transcription.durationMs = words.map(\.endMs).max()

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
                diarizationApplied: diarizationApplied
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
                    diarizationRequested: diarizationRequested
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

    private static func commonDetectedLanguage(
        from sourceResults: [MeetingTranscriptFinalizer.SourceTranscript]
    ) -> String? {
        let languages = Set(sourceResults.compactMap { source in
            source.result.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        return languages.count == 1 ? languages.first : nil
    }

    private func completeTranscription(
        source: TelemetryTranscriptionSource,
        transcription: inout Transcription,
        operation: TranscriptionOperationContext,
        rawText: String,
        processingStartedAt: Date,
        diarizationRequested: Bool,
        diarizationApplied: Bool
    ) async throws -> Transcription {
        let mode = processingMode()
        var customWords: [CustomWord] = []
        var snippets: [TextSnippet] = []
        if mode.usesDeterministicPipeline {
            do { customWords = try customWordRepo?.fetchEnabled() ?? [] }
            catch { logger.error("Failed to fetch custom words: \(error.localizedDescription, privacy: .public)") }
            do { snippets = try snippetRepo?.fetchEnabled() ?? [] }
            catch { logger.error("Failed to fetch snippets: \(error.localizedDescription, privacy: .public)") }
        }

        let refinement = await textRefinementService.refine(
            rawText: rawText,
            mode: mode,
            customWords: customWords,
            snippets: snippets
        )
        let baseText = refinement.text ?? rawText
        let formattedTranscript = try await formatTranscriptIfNeeded(baseText)
        transcription.cleanTranscript = formattedTranscript ?? refinement.text

        if !refinement.expandedSnippetIDs.isEmpty {
            try? snippetRepo?.incrementUseCount(ids: refinement.expandedSnippetIDs)
        }

        let derivationSource = transcription.cleanTranscript ?? transcription.rawTranscript
        transcription.derivedTitle = TitleDeriver.derive(from: derivationSource) ?? ""
        transcription.derivedSnippet = SnippetDeriver.derive(
            from: derivationSource,
            excluding: transcription.derivedTitle
        ) ?? ""

        transcription.status = .completed
        transcription.updatedAt = Date()
        try transcriptionRepo.save(transcription)

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
            diarizationApplied: diarizationApplied
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
            diarizationApplied: diarizationApplied
        )

        return transcription
    }

    private func formatTranscriptIfNeeded(_ text: String) async throws -> String? {
        guard shouldUseAIFormatter(), let llmService else {
            return nil
        }

        let promptTemplate = aiFormatterPromptTemplate()
        // Normalize before comparing: `AIFormatter.renderPrompt` passes the
        // template through `normalizedPromptTemplate` before sending, which
        // trims whitespace and folds legacy-v1 prompts back onto the current
        // default. Raw comparison would report those cases as custom prompts
        // even though the LLM sees the shipped default.
        let defaultPromptUsed = AIFormatter.normalizedPromptTemplate(promptTemplate)
            == AIFormatter.defaultPromptTemplate
        do {
            let formatted = try await llmService.formatTranscript(
                transcript: text,
                promptTemplate: promptTemplate,
                source: .transcription,
                defaultPromptUsed: defaultPromptUsed
            )
            let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            if error is CancellationError {
                throw error
            }
            logger.warning("AI formatter failed; falling back to standard cleanup error=\(error.localizedDescription, privacy: .public)")
            let message = "\(error.localizedDescription) Used standard cleanup."
            NotificationCenter.default.post(
                name: .macParakeetAIFormatterWarning,
                object: nil,
                userInfo: [
                    "source": "transcription",
                    "message": message,
                ]
            )
            return nil
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
            errorType: errorType
        ))
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv"]

    private static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}

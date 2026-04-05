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
    func transcribeURL(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> Transcription
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
}

public actor TranscriptionService: TranscriptionServiceProtocol {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "TranscriptionService")
    private let audioProcessor: AudioProcessorProtocol
    private let sttClient: STTClientProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let entitlements: EntitlementsChecking?
    private let customWordRepo: CustomWordRepositoryProtocol?
    private let snippetRepo: TextSnippetRepositoryProtocol?
    private let processingMode: @Sendable () -> Dictation.ProcessingMode
    private let textRefinementService: TextRefinementService
    private let shouldKeepDownloadedAudio: @Sendable () -> Bool
    private let shouldDiarize: @Sendable () -> Bool
    private let youtubeDownloader: YouTubeDownloading?
    private let diarizationService: DiarizationServiceProtocol?

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttClient: STTClientProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        shouldKeepDownloadedAudio: (@Sendable () -> Bool)? = nil,
        shouldDiarize: (@Sendable () -> Bool)? = nil,
        youtubeDownloader: YouTubeDownloading? = nil,
        diarizationService: DiarizationServiceProtocol? = nil
    ) {
        self.audioProcessor = audioProcessor
        self.sttClient = sttClient
        self.transcriptionRepo = transcriptionRepo
        self.entitlements = entitlements
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.processingMode = processingMode ?? { .raw }
        self.textRefinementService = TextRefinementService()
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
            sourceType: sourceType,
            onProgress: onProgress
        )
    }

    public func transcribeMeeting(
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        return try await transcribe(
            fileURL: recording.mixedAudioURL,
            storedFileURL: recording.mixedAudioURL,
            displayFileName: recording.displayName,
            source: .meeting,
            sourceType: .meeting,
            meetingSpeakerMetadata: recording.preparedTranscript,
            onProgress: onProgress
        )
    }

    private func transcribe(
        fileURL: URL,
        storedFileURL: URL?,
        displayFileName: String?,
        source: TelemetryTranscriptionSource,
        sourceType: Transcription.SourceType,
        meetingSpeakerMetadata: MeetingRealtimeTranscript? = nil,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        let fileName = displayFileName ?? storedFileURL?.lastPathComponent ?? fileURL.lastPathComponent
        let fileSize = storedFileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int).flatMap { $0 }
        }

        var transcription = Transcription(
            fileName: fileName,
            filePath: storedFileURL?.path,
            fileSizeBytes: fileSize,
            status: .processing,
            sourceType: sourceType
        )
        try transcriptionRepo.save(transcription)
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
            transcription: &transcription,
            tempFiles: [],
            meetingSpeakerMetadata: meetingSpeakerMetadata,
            onProgress: onProgress
        )
    }

    public func transcribeURL(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil) async throws -> Transcription {
        guard let downloader = youtubeDownloader else {
            throw YouTubeDownloadError.ytDlpNotFound
        }

        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        onProgress?(.downloading(percent: 0))
        let downloadResult = try await downloader.download(url: urlString) { percent in
            onProgress?(.downloading(percent: percent))
        }
        onProgress?(.downloading(percent: 100))
        try Task.checkCancellation()
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
        try transcriptionRepo.save(transcription)
        Telemetry.send(.transcriptionStarted(source: .youtube, audioDurationSeconds: nil))

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
            transcription: &transcription,
            tempFiles: [downloadResult.audioFileURL],
            cleanUpDownloadedFiles: !keepDownloadedAudio,
            onProgress: onProgress
        )
    }

    // MARK: - Private

    private func transcribeAudio(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        transcription: inout Transcription,
        tempFiles: [URL],
        cleanUpDownloadedFiles: Bool = true,
        meetingSpeakerMetadata: MeetingRealtimeTranscript? = nil,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        var wavURL: URL?
        let processingStartedAt = Date()
        do {
            onProgress?(.converting)
            wavURL = try await audioProcessor.convert(fileURL: fileURL)

            guard let wavURL else {
                throw AudioProcessorError.conversionFailed("Failed to produce WAV output")
            }

            onProgress?(.transcribing(percent: 0))
            let sttProgress: (@Sendable (Int, Int) -> Void)? = onProgress.map { callback in
                { @Sendable current, total in
                    let pct = total > 0 ? Int(Double(current) / Double(total) * 100) : 0
                    callback(.transcribing(percent: min(pct, 99)))
                }
            }
            let result = try await sttClient.transcribe(audioPath: wavURL.path, onProgress: sttProgress)

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
            transcription.durationMs = result.words.last?.endMs

            if source == .meeting, let meetingSpeakerMetadata {
                let speakerSegments = meetingSpeakerMetadata.diarizationSegments.map {
                    SpeakerSegment(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs)
                }
                transcription.wordTimestamps = SpeakerMerger.mergeWordTimestampsWithSpeakers(
                    words: words,
                    segments: speakerSegments
                )
                transcription.speakerCount = meetingSpeakerMetadata.speakerCount
                transcription.speakers = meetingSpeakerMetadata.speakers
                transcription.diarizationSegments = meetingSpeakerMetadata.diarizationSegments
            } else if let diarizationService, shouldDiarize() {
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
                    Telemetry.send(.diarizationCompleted(
                        source: source,
                        speakerCount: diarResult.speakerCount,
                        durationSeconds: diarDuration
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.error("diarization_failed error=\(error.localizedDescription, privacy: .public)")
                    Telemetry.send(.diarizationFailed(
                        source: source,
                        errorType: String(describing: type(of: error)),
                        errorDetail: TelemetryErrorClassifier.errorDetail(error)
                    ))
                }
            }

            let completed = try await completeTranscription(
                source: source,
                transcription: &transcription,
                rawText: result.text,
                processingStartedAt: processingStartedAt
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
                    audioDurationSeconds: audioDurationSeconds
                ))
            } else {
                Telemetry.send(.transcriptionFailed(
                    source: source,
                    errorType: Self.errorType(for: error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
            }

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
            throw error
        }
    }

    private func completeTranscription(
        source: TelemetryTranscriptionSource,
        transcription: inout Transcription,
        rawText: String,
        processingStartedAt: Date
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
        transcription.cleanTranscript = refinement.text

        if !refinement.expandedSnippetIDs.isEmpty {
            try? snippetRepo?.incrementUseCount(ids: refinement.expandedSnippetIDs)
        }

        transcription.status = .completed
        transcription.updatedAt = Date()
        try transcriptionRepo.save(transcription)

        let wordCount = transcription.rawTranscript?.split(whereSeparator: \.isWhitespace).count ?? 0
        let audioDurationSeconds = transcription.durationMs.map { Double($0) / 1000.0 }
        let processingSeconds = Date().timeIntervalSince(processingStartedAt)
        Telemetry.send(.transcriptionCompleted(
            source: source,
            audioDurationSeconds: audioDurationSeconds,
            processingSeconds: processingSeconds,
            wordCount: wordCount
        ))

        return transcription
    }

    private static func errorType(for error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv"]

    private static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}

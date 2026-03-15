import Foundation
import OSLog

public protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> Transcription
    func transcribeURL(urlString: String, onProgress: (@Sendable (String) -> Void)?) async throws -> Transcription
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
        self.youtubeDownloader = youtubeDownloader
        self.diarizationService = diarizationService
    }

    public func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource = .file,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Transcription {
        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        let fileName = fileURL.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int).flatMap { $0 }

        var transcription = Transcription(
            fileName: fileName,
            filePath: fileURL.path,
            fileSizeBytes: fileSize,
            status: .processing
        )
        try transcriptionRepo.save(transcription)
        Telemetry.send(.transcriptionStarted(source: source, audioDurationSeconds: nil))

        return try await transcribeAudio(
            fileURL: fileURL,
            source: source,
            transcription: &transcription,
            tempFiles: [],
            onProgress: onProgress
        )
    }

    public func transcribeURL(urlString: String, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Transcription {
        guard let downloader = youtubeDownloader else {
            throw YouTubeDownloadError.ytDlpNotFound
        }

        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        onProgress?("Downloading audio... 0%")
        let downloadResult = try await downloader.download(url: urlString) { percent in
            onProgress?("Downloading audio... \(percent)%")
        }
        onProgress?("Downloading audio... 100%")
        try Task.checkCancellation()
        let keepDownloadedAudio = shouldKeepDownloadedAudio()

        var transcription = Transcription(
            fileName: downloadResult.title,
            filePath: keepDownloadedAudio ? downloadResult.audioFileURL.path : nil,
            status: .processing,
            sourceURL: urlString
        )
        try transcriptionRepo.save(transcription)
        Telemetry.send(.transcriptionStarted(source: .youtube, audioDurationSeconds: nil))

        onProgress?("Transcribing...")
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
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Transcription {
        var wavURL: URL?
        let processingStartedAt = Date()
        do {
            onProgress?("Converting audio...")
            wavURL = try await audioProcessor.convert(fileURL: fileURL)

            guard let wavURL else {
                throw AudioProcessorError.conversionFailed("Failed to produce WAV output")
            }

            onProgress?("Transcribing... 0%")
            let sttProgress: (@Sendable (Int, Int) -> Void)? = onProgress.map { callback in
                { @Sendable current, total in
                    let pct = total > 0 ? Int(Double(current) / Double(total) * 100) : 0
                    callback("Transcribing... \(min(pct, 99))%")
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

            if let diarizationService {
                do {
                    onProgress?("Identifying speakers...")
                    let diarResult = try await diarizationService.diarize(audioURL: wavURL)
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
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.error("diarization_failed error=\(error.localizedDescription, privacy: .public)")
                }
            }

            let mode = processingMode()
            let customWords = mode.usesDeterministicPipeline ? ((try? customWordRepo?.fetchEnabled()) ?? []) : []
            let snippets = mode.usesDeterministicPipeline ? ((try? snippetRepo?.fetchEnabled()) ?? []) : []
            let refinement = await textRefinementService.refine(
                rawText: result.text,
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

            try? FileManager.default.removeItem(at: wavURL)
            if cleanUpDownloadedFiles {
                for tempFile in tempFiles {
                    try? FileManager.default.removeItem(at: tempFile)
                }
            }

            return transcription
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
                    errorType: Self.errorType(for: error)
                ))
            }

            if error is CancellationError {
                try? transcriptionRepo.updateStatus(
                    id: transcription.id,
                    status: .cancelled,
                    errorMessage: nil
                )
            } else {
                try? transcriptionRepo.updateStatus(
                    id: transcription.id,
                    status: .error,
                    errorMessage: error.localizedDescription
                )
            }
            throw error
        }
    }

    private static func errorType(for error: Error) -> String {
        String(describing: type(of: error))
    }
}

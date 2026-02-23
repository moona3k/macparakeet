import Foundation

public protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(fileURL: URL, onProgress: (@Sendable (String) -> Void)?) async throws -> Transcription
    func transcribeURL(urlString: String, onProgress: (@Sendable (String) -> Void)?) async throws -> Transcription
}

extension TranscriptionServiceProtocol {
    public func transcribe(fileURL: URL) async throws -> Transcription {
        try await transcribe(fileURL: fileURL, onProgress: nil)
    }
    public func transcribeURL(urlString: String) async throws -> Transcription {
        try await transcribeURL(urlString: urlString, onProgress: nil)
    }
}

public actor TranscriptionService: TranscriptionServiceProtocol {
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

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttClient: STTClientProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        shouldKeepDownloadedAudio: (@Sendable () -> Bool)? = nil,
        youtubeDownloader: YouTubeDownloading? = nil
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
    }

    public func transcribe(fileURL: URL, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Transcription {
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

        return try await transcribeAudio(fileURL: fileURL, transcription: &transcription, tempFiles: [], onProgress: onProgress)
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
        let keepDownloadedAudio = shouldKeepDownloadedAudio()

        var transcription = Transcription(
            fileName: downloadResult.title,
            filePath: keepDownloadedAudio ? downloadResult.audioFileURL.path : nil,
            status: .processing,
            sourceURL: urlString
        )
        try transcriptionRepo.save(transcription)

        onProgress?("Transcribing...")
        return try await transcribeAudio(
            fileURL: downloadResult.audioFileURL,
            transcription: &transcription,
            tempFiles: [downloadResult.audioFileURL],
            cleanUpDownloadedFiles: !keepDownloadedAudio,
            onProgress: onProgress
        )
    }

    // MARK: - Private

    private func transcribeAudio(
        fileURL: URL,
        transcription: inout Transcription,
        tempFiles: [URL],
        cleanUpDownloadedFiles: Bool = true,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Transcription {
        var wavURL: URL?
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

            // Clean up temp files
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

            try? transcriptionRepo.updateStatus(
                id: transcription.id,
                status: .error,
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }
}

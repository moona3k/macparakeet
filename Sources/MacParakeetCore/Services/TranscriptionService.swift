import Foundation

public protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(fileURL: URL) async throws -> Transcription
    func transcribeURL(urlString: String, onProgress: (@Sendable (String) -> Void)?) async throws -> Transcription
}

extension TranscriptionServiceProtocol {
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
        self.shouldKeepDownloadedAudio = shouldKeepDownloadedAudio ?? { true }
        self.youtubeDownloader = youtubeDownloader
    }

    public func transcribe(fileURL: URL) async throws -> Transcription {
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

        return try await transcribeAudio(fileURL: fileURL, transcription: &transcription, tempFiles: [])
    }

    public func transcribeURL(urlString: String, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Transcription {
        guard let downloader = youtubeDownloader else {
            throw YouTubeDownloadError.ytDlpNotFound
        }

        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        onProgress?("Downloading audio...")
        let downloadResult = try await downloader.download(url: urlString)

        var transcription = Transcription(
            fileName: downloadResult.title,
            status: .processing,
            sourceURL: urlString
        )
        try transcriptionRepo.save(transcription)

        onProgress?("Transcribing...")
        return try await transcribeAudio(
            fileURL: downloadResult.audioFileURL,
            transcription: &transcription,
            tempFiles: [downloadResult.audioFileURL],
            cleanUpDownloadedFiles: !shouldKeepDownloadedAudio()
        )
    }

    // MARK: - Private

    private func transcribeAudio(
        fileURL: URL,
        transcription: inout Transcription,
        tempFiles: [URL],
        cleanUpDownloadedFiles: Bool = true
    ) async throws -> Transcription {
        var wavURL: URL?
        do {
            wavURL = try await audioProcessor.convert(fileURL: fileURL)

            guard let wavURL else {
                throw AudioProcessorError.conversionFailed("Failed to produce WAV output")
            }
            let result = try await sttClient.transcribe(audioPath: wavURL.path)

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
            if mode != .raw {
                let customWords = (try? customWordRepo?.fetchEnabled()) ?? []
                let snippets = (try? snippetRepo?.fetchEnabled()) ?? []
                let pipeline = TextProcessingPipeline()
                let pipelineResult = pipeline.process(
                    text: result.text,
                    customWords: customWords,
                    snippets: snippets
                )
                transcription.cleanTranscript = pipelineResult.text
                if !pipelineResult.expandedSnippetIDs.isEmpty {
                    try? snippetRepo?.incrementUseCount(ids: pipelineResult.expandedSnippetIDs)
                }
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

import Foundation

public protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(fileURL: URL) async throws -> Transcription
}

public actor TranscriptionService: TranscriptionServiceProtocol {
    private let audioProcessor: AudioProcessorProtocol
    private let sttClient: STTClientProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let entitlements: EntitlementsChecking?
    private let customWordRepo: CustomWordRepositoryProtocol?
    private let snippetRepo: TextSnippetRepositoryProtocol?
    private let processingMode: @Sendable () -> Dictation.ProcessingMode

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttClient: STTClientProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil
    ) {
        self.audioProcessor = audioProcessor
        self.sttClient = sttClient
        self.transcriptionRepo = transcriptionRepo
        self.entitlements = entitlements
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.processingMode = processingMode ?? { .raw }
    }

    public func transcribe(fileURL: URL) async throws -> Transcription {
        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        let fileName = fileURL.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int).flatMap { $0 }

        // Create initial record
        var transcription = Transcription(
            fileName: fileName,
            filePath: fileURL.path,
            fileSizeBytes: fileSize,
            status: .processing
        )
        try transcriptionRepo.save(transcription)

        var wavURL: URL?
        do {
            // Convert to WAV
            wavURL = try await audioProcessor.convert(fileURL: fileURL)

            // Transcribe
            guard let wavURL else {
                throw AudioProcessorError.conversionFailed("Failed to produce WAV output")
            }
            let result = try await sttClient.transcribe(audioPath: wavURL.path)

            // Update record
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

            // Run pipeline if not raw mode
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

            // Clean up temp WAV
            try? FileManager.default.removeItem(at: wavURL)

            return transcription
        } catch {
            // Clean up temp WAV on error
            if let wavURL { try? FileManager.default.removeItem(at: wavURL) }

            // Update record with error
            try? transcriptionRepo.updateStatus(
                id: transcription.id,
                status: .error,
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }
}

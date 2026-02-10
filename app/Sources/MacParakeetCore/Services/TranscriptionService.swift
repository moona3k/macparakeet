import Foundation

public protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(fileURL: URL) async throws -> Transcription
}

public actor TranscriptionService: TranscriptionServiceProtocol {
    private let audioProcessor: AudioProcessorProtocol
    private let sttClient: STTClientProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let entitlements: EntitlementsChecking?

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttClient: STTClientProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        entitlements: EntitlementsChecking? = nil
    ) {
        self.audioProcessor = audioProcessor
        self.sttClient = sttClient
        self.transcriptionRepo = transcriptionRepo
        self.entitlements = entitlements
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

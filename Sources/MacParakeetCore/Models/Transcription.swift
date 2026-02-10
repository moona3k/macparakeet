import Foundation
import GRDB

public struct Transcription: Codable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var fileName: String
    public var filePath: String?
    public var fileSizeBytes: Int?
    public var durationMs: Int?
    public var rawTranscript: String?
    public var cleanTranscript: String?
    public var wordTimestamps: [WordTimestamp]?
    public var language: String?
    public var speakerCount: Int?
    public var speakers: [String]?
    public var status: TranscriptionStatus
    public var errorMessage: String?
    public var exportPath: String?
    public var updatedAt: Date

    public enum TranscriptionStatus: String, Codable, Sendable {
        case processing
        case completed
        case error
        case cancelled
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        fileName: String,
        filePath: String? = nil,
        fileSizeBytes: Int? = nil,
        durationMs: Int? = nil,
        rawTranscript: String? = nil,
        cleanTranscript: String? = nil,
        wordTimestamps: [WordTimestamp]? = nil,
        language: String? = "en",
        speakerCount: Int? = nil,
        speakers: [String]? = nil,
        status: TranscriptionStatus = .processing,
        errorMessage: String? = nil,
        exportPath: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.fileName = fileName
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.durationMs = durationMs
        self.rawTranscript = rawTranscript
        self.cleanTranscript = cleanTranscript
        self.wordTimestamps = wordTimestamps
        self.language = language
        self.speakerCount = speakerCount
        self.speakers = speakers
        self.status = status
        self.errorMessage = errorMessage
        self.exportPath = exportPath
        self.updatedAt = updatedAt
    }
}

public struct WordTimestamp: Codable, Sendable {
    public var word: String
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double

    public init(word: String, startMs: Int, endMs: Int, confidence: Double) {
        self.word = word
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
    }
}

extension Transcription: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptions"

    public enum Columns: String, ColumnExpression {
        case id, createdAt, fileName, filePath, fileSizeBytes, durationMs
        case rawTranscript, cleanTranscript, wordTimestamps, language
        case speakerCount, speakers, status, errorMessage, exportPath, updatedAt
    }
}

import Foundation
import GRDB

public struct Dictation: Codable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var durationMs: Int
    public var rawTranscript: String
    public var cleanTranscript: String?
    public var audioPath: String?
    public var pastedToApp: String?
    public var processingMode: ProcessingMode
    public var status: DictationStatus
    public var errorMessage: String?
    public var updatedAt: Date

    public enum ProcessingMode: String, Codable, Sendable {
        case raw
        case clean
    }

    public enum DictationStatus: String, Codable, Sendable {
        case recording
        case processing
        case completed
        case error
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        durationMs: Int,
        rawTranscript: String,
        cleanTranscript: String? = nil,
        audioPath: String? = nil,
        pastedToApp: String? = nil,
        processingMode: ProcessingMode = .raw,
        status: DictationStatus = .completed,
        errorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.rawTranscript = rawTranscript
        self.cleanTranscript = cleanTranscript
        self.audioPath = audioPath
        self.pastedToApp = pastedToApp
        self.processingMode = processingMode
        self.status = status
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

extension Dictation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictations"

    public enum Columns: String, ColumnExpression {
        case id, createdAt, durationMs, rawTranscript, cleanTranscript
        case audioPath, pastedToApp, processingMode, status, errorMessage, updatedAt
    }
}

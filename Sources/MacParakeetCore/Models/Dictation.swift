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
    public var hidden: Bool
    public var wordCount: Int

    public enum ProcessingMode: String, Codable, Sendable {
        case raw
        case clean

        /// Override default RawRepresentable init to handle deprecated mode values.
        /// Without this, `ProcessingMode(rawValue: "formal")` returns nil and callers
        /// fall back to `.raw`, silently disabling processing for upgraded users.
        public init?(rawValue: String) {
            switch rawValue {
            case "raw": self = .raw
            case "clean", "formal", "email", "code": self = .clean
            default: return nil
            }
        }

        public init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .raw
        }
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
        updatedAt: Date = Date(),
        hidden: Bool = false,
        wordCount: Int = 0
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
        self.hidden = hidden
        self.wordCount = wordCount
    }
}

public extension Dictation.ProcessingMode {
    var usesDeterministicPipeline: Bool {
        self != .raw
    }

    var displayName: String {
        switch self {
        case .raw:
            return "Raw"
        case .clean:
            return "Clean"
        }
    }

}

extension Dictation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictations"

    public enum Columns: String, ColumnExpression {
        case id, createdAt, durationMs, rawTranscript, cleanTranscript
        case audioPath, pastedToApp, processingMode, status, errorMessage, updatedAt
        case hidden, wordCount
    }
}

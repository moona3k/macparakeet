import Foundation
import GRDB

public struct Transcription: Codable, Identifiable, Sendable {
    public enum SourceType: String, Codable, Sendable {
        case file
        case youtube
        case meeting
    }

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
    public var speakers: [SpeakerInfo]?
    public var diarizationSegments: [DiarizationSegmentRecord]?
    public var summary: String?
    public var chatMessages: [ChatMessage]?
    public var status: TranscriptionStatus
    public var errorMessage: String?
    public var exportPath: String?
    public var sourceURL: String?
    public var thumbnailURL: String?
    public var channelName: String?
    public var videoDescription: String?
    public var isFavorite: Bool
    public var sourceType: SourceType
    public var recoveredFromCrash: Bool
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
        speakers: [SpeakerInfo]? = nil,
        diarizationSegments: [DiarizationSegmentRecord]? = nil,
        summary: String? = nil,
        chatMessages: [ChatMessage]? = nil,
        status: TranscriptionStatus = .processing,
        errorMessage: String? = nil,
        exportPath: String? = nil,
        sourceURL: String? = nil,
        thumbnailURL: String? = nil,
        channelName: String? = nil,
        videoDescription: String? = nil,
        isFavorite: Bool = false,
        sourceType: SourceType = .file,
        recoveredFromCrash: Bool = false,
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
        self.diarizationSegments = diarizationSegments
        self.summary = summary
        self.chatMessages = chatMessages
        self.status = status
        self.errorMessage = errorMessage
        self.exportPath = exportPath
        self.sourceURL = sourceURL
        self.thumbnailURL = thumbnailURL
        self.channelName = channelName
        self.videoDescription = videoDescription
        self.isFavorite = isFavorite
        self.sourceType = sourceType
        self.recoveredFromCrash = recoveredFromCrash
        self.updatedAt = updatedAt
    }
}

public struct WordTimestamp: Codable, Sendable, Equatable {
    public var word: String
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double
    public var speakerId: String?

    public init(word: String, startMs: Int, endMs: Int, confidence: Double, speakerId: String? = nil) {
        self.word = word
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.speakerId = speakerId
    }
}

public struct SpeakerInfo: Codable, Sendable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct DiarizationSegmentRecord: Codable, Sendable, Equatable {
    public var speakerId: String
    public var startMs: Int
    public var endMs: Int

    public init(speakerId: String, startMs: Int, endMs: Int) {
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
    }
}

extension Transcription: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptions"

    public enum Columns: String, ColumnExpression {
        case id, createdAt, fileName, filePath, fileSizeBytes, durationMs
        case rawTranscript, cleanTranscript, wordTimestamps, language
        case speakerCount, speakers, diarizationSegments, summary, chatMessages
        case status, errorMessage, exportPath, sourceURL
        case thumbnailURL, channelName, videoDescription, isFavorite, sourceType, recoveredFromCrash, updatedAt
    }

    /// Backward-compatible decoding: `speakers` column may contain old `[String]` JSON
    /// from pre-diarization transcriptions, or new `[SpeakerInfo]` JSON.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        fileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .fileSizeBytes)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript)
        cleanTranscript = try container.decodeIfPresent(String.self, forKey: .cleanTranscript)
        wordTimestamps = try container.decodeIfPresent([WordTimestamp].self, forKey: .wordTimestamps)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        speakerCount = try container.decodeIfPresent(Int.self, forKey: .speakerCount)

        // Try new [SpeakerInfo] format first, fall back to old [String] format
        if let speakerInfos = try? container.decodeIfPresent([SpeakerInfo].self, forKey: .speakers) {
            speakers = speakerInfos
        } else if let oldStrings = try? container.decodeIfPresent([String].self, forKey: .speakers) {
            speakers = oldStrings.enumerated().map { index, name in
                SpeakerInfo(id: "S\(index + 1)", label: name)
            }
        } else {
            speakers = nil
        }

        diarizationSegments = try container.decodeIfPresent([DiarizationSegmentRecord].self, forKey: .diarizationSegments)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        chatMessages = try container.decodeIfPresent([ChatMessage].self, forKey: .chatMessages)
        status = try container.decode(TranscriptionStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        exportPath = try container.decodeIfPresent(String.self, forKey: .exportPath)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailURL)
        channelName = try container.decodeIfPresent(String.self, forKey: .channelName)
        videoDescription = try container.decodeIfPresent(String.self, forKey: .videoDescription)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        if let decodedSourceType = try container.decodeIfPresent(SourceType.self, forKey: .sourceType) {
            sourceType = decodedSourceType
        } else if sourceURL != nil {
            sourceType = .youtube
        } else {
            sourceType = .file
        }
        recoveredFromCrash = try container.decodeIfPresent(Bool.self, forKey: .recoveredFromCrash) ?? false
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

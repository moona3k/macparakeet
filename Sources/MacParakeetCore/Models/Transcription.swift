import Foundation
import GRDB
import OSLog

private let transcriptionDecodeLogger = Logger(
    subsystem: "com.macparakeet.core",
    category: "Transcription.decode"
)

public struct Transcription: Codable, Identifiable, Sendable {
    public enum SourceType: String, Codable, Sendable, CaseIterable {
        case file
        case youtube
        case podcast
        case meeting
    }

    public var id: UUID
    public var createdAt: Date
    public var fileName: String
    public var filePath: String?
    public var meetingArtifactFolderPath: String?
    public var fileSizeBytes: Int?
    public var durationMs: Int?
    public var rawTranscript: String?
    public var cleanTranscript: String?
    public var wordTimestamps: [WordTimestamp]?
    public var language: String?
    public var speakerCount: Int?
    public var speakers: [SpeakerInfo]?
    public var diarizationSegments: [DiarizationSegmentRecord]?
    public var transcriptSegments: [TranscriptSegmentRecord]?
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
    public var isTranscriptEdited: Bool
    /// Free-form notes the user typed during a meeting recording.
    /// Persisted alongside the transcript so they can steer post-meeting
    /// summary generation (ADR-020 §3). `nil` for non-meeting transcripts
    /// and for meetings where the user took no notes.
    public var userNotes: String?
    /// One-shot context captured when a meeting recording starts. `nil` for
    /// non-meeting rows and legacy meetings.
    public var meetingStartContext: MeetingStartContext?
    /// STT engine that produced this transcript (`"parakeet"` / `"nemotron"` /
    /// `"cohere"` / `"whisper"`).
    /// `nil` for rows created before the v0.8 engine-attribution migration.
    public var engine: String?
    /// Engine-specific model variant id (e.g. the Whisper model id).
    /// `nil` for engines without variants and for legacy rows.
    public var engineVariant: String?
    /// Local calendar context captured when a meeting recording was started
    /// from, or probably overlaps, an EventKit event. Contains attendee data
    /// and remains local-only.
    public var calendarEventSnapshot: MeetingCalendarSnapshot?
    /// User-authored display title for non-meeting transcription rows. This is
    /// app metadata only; it does not rename or move the original source file.
    public var titleOverride: String?
    /// Display-ready title derived from the transcript content at completion
    /// (substantive first sentence, filler-stripped). `nil` when the transcript
    /// is empty or when the row predates v0.9 backfill.
    public var derivedTitle: String?
    /// Display-ready preview snippet derived from the transcript content at
    /// completion (substantive sentence in [40, 140] chars, filler-stripped).
    /// `nil` when the transcript is empty or predates v0.9 backfill.
    public var derivedSnippet: String?
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
        meetingArtifactFolderPath: String? = nil,
        fileSizeBytes: Int? = nil,
        durationMs: Int? = nil,
        rawTranscript: String? = nil,
        cleanTranscript: String? = nil,
        wordTimestamps: [WordTimestamp]? = nil,
        language: String? = "en",
        speakerCount: Int? = nil,
        speakers: [SpeakerInfo]? = nil,
        diarizationSegments: [DiarizationSegmentRecord]? = nil,
        transcriptSegments: [TranscriptSegmentRecord]? = nil,
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
        isTranscriptEdited: Bool = false,
        userNotes: String? = nil,
        meetingStartContext: MeetingStartContext? = nil,
        engine: String? = nil,
        engineVariant: String? = nil,
        calendarEventSnapshot: MeetingCalendarSnapshot? = nil,
        titleOverride: String? = nil,
        derivedTitle: String? = nil,
        derivedSnippet: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.fileName = fileName
        self.filePath = filePath
        self.meetingArtifactFolderPath = meetingArtifactFolderPath
        self.fileSizeBytes = fileSizeBytes
        self.durationMs = durationMs
        self.rawTranscript = rawTranscript
        self.cleanTranscript = cleanTranscript
        self.wordTimestamps = wordTimestamps
        self.language = language
        self.speakerCount = speakerCount
        self.speakers = speakers
        self.diarizationSegments = diarizationSegments
        self.transcriptSegments = transcriptSegments
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
        self.isTranscriptEdited = isTranscriptEdited
        self.userNotes = userNotes
        self.meetingStartContext = meetingStartContext
        self.engine = engine
        self.engineVariant = engineVariant
        self.calendarEventSnapshot = calendarEventSnapshot
        self.titleOverride = Self.normalizedTitleOverride(from: titleOverride)
        self.derivedTitle = derivedTitle
        self.derivedSnippet = derivedSnippet
        self.updatedAt = updatedAt
    }
}

extension Transcription {
    /// Whether this transcription carries word-level timing. This is the source
    /// of truth for the "Timed" transcript view and for whether timestamps can
    /// be exported. Plain-text engines (such as Cohere) and older pre-timestamp
    /// records leave this `false`.
    public var hasWordTimestamps: Bool {
        guard let wordTimestamps else { return false }
        return !wordTimestamps.isEmpty
    }

    /// Whether words carry diarized speaker IDs that can be exported as speaker
    /// labels. Requires both a non-empty `speakers` roster and at least one word
    /// attributed to a speaker. A transcript can list `speakers` without any word
    /// being attributed — e.g. older records where diarization ran on an engine
    /// that produced no word timings — so the speaker count alone is not enough.
    public var hasSpeakerLabeledWords: Bool {
        guard let speakers, !speakers.isEmpty,
              let wordTimestamps else { return false }
        return wordTimestamps.contains { $0.speakerId != nil }
    }

    public static func normalizedTitleOverride(from title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public var normalizedTitleOverride: String? {
        Self.normalizedTitleOverride(from: titleOverride)
    }

    public var effectiveDisplayTitle: String {
        if sourceType == .meeting {
            let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? fileName : name
        }
        if let titleOverride = normalizedTitleOverride {
            return titleOverride
        }
        if let derived = derivedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !derived.isEmpty {
            return derived
        }
        return fileName
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

public struct TranscriptSegmentWordRange: Codable, Sendable, Equatable {
    public var startIndex: Int
    public var endIndexExclusive: Int

    public init(startIndex: Int, endIndexExclusive: Int) {
        self.startIndex = startIndex
        self.endIndexExclusive = endIndexExclusive
    }
}

public struct TranscriptSegmentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startMs: Int
    public var endMs: Int
    public var speakerId: String?
    public var speakerLabel: String
    public var text: String
    public var wordRange: TranscriptSegmentWordRange

    public init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        speakerId: String?,
        speakerLabel: String,
        text: String,
        wordRange: TranscriptSegmentWordRange
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.text = text
        self.wordRange = wordRange
    }

    public static func updatingSpeakerLabels(
        in segments: [TranscriptSegmentRecord]?,
        using speakers: [SpeakerInfo]?
    ) -> [TranscriptSegmentRecord]? {
        guard var segments,
              !segments.isEmpty,
              let speakers,
              !speakers.isEmpty
        else {
            return segments
        }

        var labelsBySpeakerID: [String: String] = [:]
        for speaker in speakers {
            labelsBySpeakerID[speaker.id] = speaker.label
        }

        for index in segments.indices {
            guard let speakerId = segments[index].speakerId,
                  let label = labelsBySpeakerID[speakerId]
            else { continue }
            segments[index].speakerLabel = label
        }
        return segments
    }
}

extension Transcription: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptions"

    public enum Columns: String, ColumnExpression {
        case id, createdAt, fileName, filePath, meetingArtifactFolderPath, fileSizeBytes, durationMs
        case rawTranscript, cleanTranscript, wordTimestamps, language
        case speakerCount, speakers, diarizationSegments, transcriptSegments, chatMessages
        case status, errorMessage, exportPath, sourceURL
        case thumbnailURL, channelName, videoDescription, isFavorite, sourceType, recoveredFromCrash, isTranscriptEdited, userNotes, meetingStartContext, engine, engineVariant, titleOverride, derivedTitle, derivedSnippet, updatedAt
        case calendarEventSnapshot
    }

    /// Backward-compatible decoding: `speakers` column may contain old `[String]` JSON
    /// from pre-diarization transcriptions, or new `[SpeakerInfo]` JSON.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        meetingArtifactFolderPath = try container.decodeIfPresent(String.self, forKey: .meetingArtifactFolderPath)
        fileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .fileSizeBytes)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript)
        cleanTranscript = try container.decodeIfPresent(String.self, forKey: .cleanTranscript)
        wordTimestamps = try container.decodeIfPresent([WordTimestamp].self, forKey: .wordTimestamps)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        speakerCount = try container.decodeIfPresent(Int.self, forKey: .speakerCount)

        // Try new [SpeakerInfo] format first, fall back to old [String] format.
        // If both shapes fail to decode but the key is present, the data is
        // genuinely malformed (a string array would round-trip via the
        // fallback). Log so the corruption is observable in Console.app
        // rather than silently dropping speaker info on read.
        if let speakerInfos = try? container.decodeIfPresent([SpeakerInfo].self, forKey: .speakers) {
            speakers = speakerInfos
        } else if let oldStrings = try? container.decodeIfPresent([String].self, forKey: .speakers) {
            speakers = oldStrings.enumerated().map { index, name in
                SpeakerInfo(id: "S\(index + 1)", label: name)
            }
        } else {
            speakers = nil
            let speakersIsExplicitNull = (try? container.decodeNil(forKey: .speakers)) == true
            if container.contains(.speakers), !speakersIsExplicitNull {
                let recordIDString = id.uuidString
                transcriptionDecodeLogger.warning(
                    "transcription_speakers_decode_failed id=\(recordIDString, privacy: .public)"
                )
            }
        }

        diarizationSegments = try container.decodeIfPresent([DiarizationSegmentRecord].self, forKey: .diarizationSegments)
        transcriptSegments = try container.decodeIfPresent([TranscriptSegmentRecord].self, forKey: .transcriptSegments)
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
        isTranscriptEdited = try container.decodeIfPresent(Bool.self, forKey: .isTranscriptEdited) ?? false
        userNotes = try container.decodeIfPresent(String.self, forKey: .userNotes)
        meetingStartContext = (try? container.decodeIfPresent(MeetingStartContext.self, forKey: .meetingStartContext)) ?? nil
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        engineVariant = try container.decodeIfPresent(String.self, forKey: .engineVariant)
        calendarEventSnapshot = (try? container.decodeIfPresent(
            MeetingCalendarSnapshot.self,
            forKey: .calendarEventSnapshot
        )) ?? nil
        titleOverride = Self.normalizedTitleOverride(from: try container.decodeIfPresent(String.self, forKey: .titleOverride))
        derivedTitle = try container.decodeIfPresent(String.self, forKey: .derivedTitle)
        derivedSnippet = try container.decodeIfPresent(String.self, forKey: .derivedSnippet)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

import Foundation

public protocol MeetingArtifactStoring: Sendable {
    @discardableResult
    func materialize(
        transcription: Transcription,
        promptResults: [PromptResult]
    ) async throws -> MeetingArtifactSnapshot

    @discardableResult
    func materialize(
        projection: SpeakerAttributionProjection,
        promptResults: [PromptResult]
    ) async throws -> MeetingArtifactSnapshot
}

public extension MeetingArtifactStoring {
    func materialize(
        projection: SpeakerAttributionProjection,
        promptResults: [PromptResult]
    ) async throws -> MeetingArtifactSnapshot {
        try await materialize(
            transcription: projection.effectiveTranscription,
            promptResults: promptResults
        )
    }
}

public enum MeetingArtifactError: Error, LocalizedError, Sendable {
    case notMeeting
    case missingSessionFolder

    public var errorDescription: String? {
        switch self {
        case .notMeeting:
            return "Meeting artifacts can only be materialized for meeting recordings."
        case .missingSessionFolder:
            return "Meeting artifact folder could not be resolved from the meeting audio path."
        }
    }
}

public struct MeetingArtifactSnapshot: Codable, Sendable, Equatable {
    public let schema: String
    public let schemaVersion: Int
    public let generatedAt: Date
    public let meetingID: UUID
    public let title: String
    public let folderPath: String
    public let manifestPath: String
    public let markdownPath: String?
    public let rawMicrophoneAudioPath: String?
    public let cleanedMicrophoneAudioPath: String?
    public let rawSystemAudioPath: String?
    public let playbackAudioPath: String?
    public let transcriptPath: String
    public let notesPath: String?
    public let promptResultsPath: String
    public let promptResultsDirectoryPath: String
    public let promptResultCount: Int
    public let speakerCorrectionsApplied: Bool
    public let speakerCorrectionRevision: Int
    public let calendarEventSnapshot: MeetingCalendarSnapshot?
    public let meetingCaptureReport: MeetingCaptureReport?

    private enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion
        case generatedAt
        case meetingID
        case title
        case folderPath
        case manifestPath
        case markdownPath
        case rawMicrophoneAudioPath
        case cleanedMicrophoneAudioPath
        case rawSystemAudioPath
        case playbackAudioPath
        case transcriptPath
        case notesPath
        case promptResultsPath
        case promptResultsDirectoryPath
        case promptResultCount
        case speakerCorrectionsApplied
        case speakerCorrectionRevision
        case calendarEventSnapshot
        case meetingCaptureReport
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        meetingID = try values.decode(UUID.self, forKey: .meetingID)
        title = try values.decode(String.self, forKey: .title)
        folderPath = try values.decode(String.self, forKey: .folderPath)
        manifestPath = try values.decode(String.self, forKey: .manifestPath)
        markdownPath = try values.decodeIfPresent(String.self, forKey: .markdownPath)
        rawMicrophoneAudioPath = try values.decodeIfPresent(String.self, forKey: .rawMicrophoneAudioPath)
        cleanedMicrophoneAudioPath = try values.decodeIfPresent(String.self, forKey: .cleanedMicrophoneAudioPath)
        rawSystemAudioPath = try values.decodeIfPresent(String.self, forKey: .rawSystemAudioPath)
        playbackAudioPath = try values.decodeIfPresent(String.self, forKey: .playbackAudioPath)
        transcriptPath = try values.decode(String.self, forKey: .transcriptPath)
        notesPath = try values.decodeIfPresent(String.self, forKey: .notesPath)
        promptResultsPath = try values.decode(String.self, forKey: .promptResultsPath)
        promptResultsDirectoryPath = try values.decode(String.self, forKey: .promptResultsDirectoryPath)
        promptResultCount = try values.decode(Int.self, forKey: .promptResultCount)
        speakerCorrectionsApplied = try values.decodeIfPresent(Bool.self, forKey: .speakerCorrectionsApplied) ?? false
        speakerCorrectionRevision = try values.decodeIfPresent(Int.self, forKey: .speakerCorrectionRevision) ?? 0
        calendarEventSnapshot = try values.decodeIfPresent(MeetingCalendarSnapshot.self, forKey: .calendarEventSnapshot)
        meetingCaptureReport = try values.decodeIfPresent(MeetingCaptureReport.self, forKey: .meetingCaptureReport)
    }

    public init(
        schema: String = MeetingArtifactStore.schema,
        schemaVersion: Int = MeetingArtifactStore.schemaVersion,
        generatedAt: Date,
        meetingID: UUID,
        title: String,
        folderPath: String,
        manifestPath: String,
        markdownPath: String?,
        rawMicrophoneAudioPath: String? = nil,
        cleanedMicrophoneAudioPath: String? = nil,
        rawSystemAudioPath: String? = nil,
        playbackAudioPath: String? = nil,
        transcriptPath: String,
        notesPath: String?,
        promptResultsPath: String,
        promptResultsDirectoryPath: String,
        promptResultCount: Int,
        speakerCorrectionsApplied: Bool = false,
        speakerCorrectionRevision: Int = 0,
        calendarEventSnapshot: MeetingCalendarSnapshot? = nil,
        meetingCaptureReport: MeetingCaptureReport? = nil
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.meetingID = meetingID
        self.title = title
        self.folderPath = folderPath
        self.manifestPath = manifestPath
        self.markdownPath = markdownPath
        self.rawMicrophoneAudioPath = rawMicrophoneAudioPath
        self.cleanedMicrophoneAudioPath = cleanedMicrophoneAudioPath
        self.rawSystemAudioPath = rawSystemAudioPath
        self.playbackAudioPath = playbackAudioPath
        self.transcriptPath = transcriptPath
        self.notesPath = notesPath
        self.promptResultsPath = promptResultsPath
        self.promptResultsDirectoryPath = promptResultsDirectoryPath
        self.promptResultCount = promptResultCount
        self.speakerCorrectionsApplied = speakerCorrectionsApplied
        self.speakerCorrectionRevision = speakerCorrectionRevision
        self.calendarEventSnapshot = calendarEventSnapshot
        self.meetingCaptureReport = meetingCaptureReport
    }
}

public final class MeetingArtifactStore: MeetingArtifactStoring, @unchecked Sendable {
    public static let schema = "com.macparakeet.meeting-session"
    public static let schemaVersion = 1
    public static let manifestFileName = "manifest.json"
    public static let markdownFileName = "meeting.md"
    public static let transcriptFileName = "transcript.json"
    public static let promptResultsFileName = "prompt-results.json"
    public static let promptResultsDirectoryName = "prompt-results"

    private let fileManager: FileManager
    private let markdownWriter: @Sendable (String, String) throws -> Void
    private let speakerAttributionReader: SpeakerAttributionReading?

    public init(
        fileManager: FileManager = .default,
        speakerAttributionReader: SpeakerAttributionReading? = nil
    ) {
        self.fileManager = fileManager
        self.speakerAttributionReader = speakerAttributionReader
        markdownWriter = { content, path in
            try content.write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    init(
        fileManager: FileManager = .default,
        speakerAttributionReader: SpeakerAttributionReading? = nil,
        markdownWriter: @escaping @Sendable (String, String) throws -> Void
    ) {
        self.fileManager = fileManager
        self.speakerAttributionReader = speakerAttributionReader
        self.markdownWriter = markdownWriter
    }

    @discardableResult
    public func materialize(
        transcription: Transcription,
        promptResults: [PromptResult] = []
    ) async throws -> MeetingArtifactSnapshot {
        let projection = try speakerAttributionReader?.resolve(transcription: transcription)
        if let projection {
            return try await materialize(projection: projection, promptResults: promptResults)
        }
        return try await materializeResolved(
            transcription: transcription,
            projection: nil,
            promptResults: promptResults
        )
    }

    public func materialize(
        projection: SpeakerAttributionProjection,
        promptResults: [PromptResult] = []
    ) async throws -> MeetingArtifactSnapshot {
        try await materializeResolved(
            transcription: projection.effectiveTranscription,
            projection: projection,
            promptResults: promptResults
        )
    }

    private func materializeResolved(
        transcription: Transcription,
        projection: SpeakerAttributionProjection?,
        promptResults: [PromptResult]
    ) async throws -> MeetingArtifactSnapshot {
        guard transcription.sourceType == .meeting else {
            throw MeetingArtifactError.notMeeting
        }
        guard let folderURL = Self.sessionFolderURL(for: transcription) else {
            throw MeetingArtifactError.missingSessionFolder
        }
        let effectiveTranscription = transcription

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let generatedAt = Date()
        let transcriptURL = folderURL.appendingPathComponent(Self.transcriptFileName)
        let promptResultsURL = folderURL.appendingPathComponent(Self.promptResultsFileName)
        let promptResultsDirectoryURL = folderURL.appendingPathComponent(Self.promptResultsDirectoryName, isDirectory: true)
        let notesURL = MeetingNotesFile.fileURL(for: folderURL)

        let notesPath: String?
        try await MeetingNotesFile.write(
            notes: effectiveTranscription.userNotes,
            displayName: effectiveTranscription.fileName,
            to: folderURL,
            fileManager: MeetingNotesFile.SendableFileManager(fileManager)
        )
        notesPath = fileManager.fileExists(atPath: notesURL.path) ? notesURL.path : nil

        let resultFiles = try writePromptResults(
            promptResults,
            meeting: effectiveTranscription,
            jsonURL: promptResultsURL,
            directoryURL: promptResultsDirectoryURL
        )

        try writeJSON(
            MeetingArtifactTranscript(effectiveTranscription, projection: projection),
            to: transcriptURL
        )

        let manifestURL = folderURL.appendingPathComponent(Self.manifestFileName)
        let artifactPaths = MeetingMarkdownArtifactPaths.resolve(
            transcription: effectiveTranscription,
            promptResults: promptResults,
            fileManager: fileManager
        )
        let snapshot = MeetingArtifactSnapshot(
            generatedAt: generatedAt,
            meetingID: transcription.id,
            title: transcription.fileName,
            folderPath: folderURL.path,
            manifestPath: manifestURL.path,
            markdownPath: artifactPaths.markdownPath,
            rawMicrophoneAudioPath: artifactPaths.rawMicrophoneAudioPath,
            cleanedMicrophoneAudioPath: artifactPaths.cleanedMicrophoneAudioPath,
            rawSystemAudioPath: artifactPaths.rawSystemAudioPath,
            playbackAudioPath: artifactPaths.playbackAudioPath,
            transcriptPath: transcriptURL.path,
            notesPath: notesPath,
            promptResultsPath: promptResultsURL.path,
            promptResultsDirectoryPath: promptResultsDirectoryURL.path,
            promptResultCount: promptResults.count,
            speakerCorrectionsApplied: projection?.correctionsApplied ?? false,
            speakerCorrectionRevision: projection?.correctionRevision ?? 0,
            calendarEventSnapshot: effectiveTranscription.calendarEventSnapshot,
            meetingCaptureReport: effectiveTranscription.meetingCaptureReport
        )
        if let markdownPath = artifactPaths.markdownPath {
            let markdown = MeetingMarkdownRenderer().render(
                transcription: effectiveTranscription,
                promptResults: promptResults,
                artifactPaths: artifactPaths,
                speakerCorrectionsApplied: projection?.correctionsApplied ?? false,
                speakerCorrectionRevision: projection?.correctionRevision ?? 0
            )
            try markdownWriter(markdown, markdownPath)
        }
        try writeJSON(
            MeetingArtifactManifest(
                snapshot: snapshot,
                transcription: effectiveTranscription,
                artifactPaths: artifactPaths,
                promptResultFiles: resultFiles
            ),
            to: manifestURL
        )

        return snapshot
    }

    public static func sessionFolderURL(for transcription: Transcription) -> URL? {
        guard transcription.sourceType == .meeting else {
            return nil
        }
        if let folderPath = normalizedPath(transcription.meetingArtifactFolderPath) {
            return URL(fileURLWithPath: folderPath, isDirectory: true)
        }
        guard let filePath = transcription.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: filePath).deletingLastPathComponent()
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func writePromptResults(
        _ promptResults: [PromptResult],
        meeting: Transcription,
        jsonURL: URL,
        directoryURL: URL
    ) throws -> [MeetingArtifactPromptResultFile] {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let records = promptResults.enumerated().map { index, result in
            MeetingArtifactPromptResult(result, index: index + 1)
        }
        try writeJSON(records, to: jsonURL)

        var files: [MeetingArtifactPromptResultFile] = []
        for record in records {
            let fileURL = directoryURL.appendingPathComponent(
                Self.promptResultMarkdownFileName(index: record.index, name: record.name)
            )
            try record.markdown(meetingTitle: meeting.fileName).write(
                to: fileURL,
                atomically: true,
                encoding: .utf8
            )
            files.append(MeetingArtifactPromptResultFile(
                id: record.id,
                name: record.name,
                path: fileURL.path
            ))
        }
        return files
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.makeEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func sanitizedFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "result" : String(cleaned.prefix(80))
    }

    public static func promptResultMarkdownFileName(index: Int, name: String) -> String {
        "\(String(format: "%02d", index))-\(sanitizedFileName(name)).md"
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private struct MeetingArtifactManifest: Codable {
    let schema: String
    let schemaVersion: Int
    let generatedAt: Date
    let meeting: MeetingArtifactMeetingSummary
    let files: MeetingArtifactFiles
    let promptResults: [MeetingArtifactPromptResultFile]

    init(
        snapshot: MeetingArtifactSnapshot,
        transcription: Transcription,
        artifactPaths: MeetingMarkdownArtifactPaths,
        promptResultFiles: [MeetingArtifactPromptResultFile]
    ) {
        schema = snapshot.schema
        schemaVersion = snapshot.schemaVersion
        generatedAt = snapshot.generatedAt
        meeting = MeetingArtifactMeetingSummary(transcription)
        files = MeetingArtifactFiles(paths: artifactPaths)
        promptResults = promptResultFiles
    }
}

private struct MeetingArtifactMeetingSummary: Codable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let durationMs: Int?
    let status: Transcription.TranscriptionStatus
    let language: String?
    let engine: String?
    let engineVariant: String?
    let calendarEventSnapshot: MeetingCalendarSnapshot?
    let meetingCaptureReport: MeetingCaptureReport?
    let recoveredFromCrash: Bool
    let isTranscriptEdited: Bool
    let startContext: MeetingStartContext?

    init(_ transcription: Transcription) {
        id = transcription.id
        title = transcription.fileName
        createdAt = transcription.createdAt
        updatedAt = transcription.updatedAt
        durationMs = transcription.durationMs
        status = transcription.status
        language = transcription.language
        engine = transcription.engine
        engineVariant = transcription.engineVariant
        calendarEventSnapshot = transcription.calendarEventSnapshot
        meetingCaptureReport = transcription.meetingCaptureReport
        recoveredFromCrash = transcription.recoveredFromCrash
        isTranscriptEdited = transcription.isTranscriptEdited
        startContext = transcription.meetingStartContext
    }
}

private struct MeetingArtifactFiles: Codable {
    let folderPath: String
    let playbackAudioPath: String?
    let rawMicrophoneAudioPath: String?
    let cleanedMicrophoneAudioPath: String?
    let rawSystemAudioPath: String?
    let metadataPath: String?
    let manifestPath: String
    let markdownPath: String?
    let transcriptPath: String
    let notesPath: String?
    let promptResultsPath: String
    let promptResultsDirectoryPath: String

    init(paths: MeetingMarkdownArtifactPaths) {
        folderPath = paths.artifactFolderPath ?? ""
        playbackAudioPath = paths.playbackAudioPath
        rawMicrophoneAudioPath = paths.rawMicrophoneAudioPath
        cleanedMicrophoneAudioPath = paths.cleanedMicrophoneAudioPath
        rawSystemAudioPath = paths.rawSystemAudioPath
        metadataPath = paths.metadataPath
        manifestPath = paths.manifestPath ?? ""
        markdownPath = paths.markdownPath
        transcriptPath = paths.transcriptPath ?? ""
        notesPath = paths.notesPath
        promptResultsPath = paths.promptResultsPath ?? ""
        promptResultsDirectoryPath = paths.promptResultsDirectoryPath ?? ""
    }
}

private struct MeetingArtifactTranscript: Codable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let durationMs: Int?
    let status: Transcription.TranscriptionStatus
    let rawTranscript: String?
    let cleanTranscript: String?
    let transcript: String
    let wordTimestamps: [WordTimestamp]?
    let speakerCount: Int?
    let speakers: [SpeakerInfo]?
    let diarizationSegments: [DiarizationSegmentRecord]?
    let transcriptSegments: [MeetingArtifactTranscriptSegment]?
    let speakerCorrectionsApplied: Bool
    let speakerCorrectionRevision: Int
    let userNotes: String?
    let language: String?
    let engine: String?
    let engineVariant: String?
    let calendarEventSnapshot: MeetingCalendarSnapshot?
    let meetingCaptureReport: MeetingCaptureReport?
    let sourceURL: String?
    let sourceType: Transcription.SourceType
    let recoveredFromCrash: Bool
    let isTranscriptEdited: Bool
    let startContext: MeetingStartContext?

    init(_ transcription: Transcription, projection: SpeakerAttributionProjection?) {
        id = transcription.id
        title = transcription.fileName
        createdAt = transcription.createdAt
        updatedAt = transcription.updatedAt
        durationMs = transcription.durationMs
        status = transcription.status
        rawTranscript = transcription.rawTranscript
        cleanTranscript = transcription.cleanTranscript
        transcript = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        wordTimestamps = transcription.wordTimestamps
        speakerCount = transcription.speakerCount
        speakers = transcription.speakers
        diarizationSegments = transcription.diarizationSegments
        let runsBySegmentID = Dictionary(
            (projection?.attribution.durableSegments ?? []).map {
                ($0.base.id, $0.speakerRuns)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let labelsBySpeakerID = Dictionary(
            (projection?.attribution.speakers ?? transcription.speakers ?? []).map {
                ($0.id, $0.label)
            },
            uniquingKeysWith: { first, _ in first }
        )
        transcriptSegments = transcription.transcriptSegments?.map {
            MeetingArtifactTranscriptSegment(
                $0,
                speakerRuns: runsBySegmentID[$0.id],
                labelsBySpeakerID: labelsBySpeakerID
            )
        }
        speakerCorrectionsApplied = projection?.correctionsApplied ?? false
        speakerCorrectionRevision = projection?.correctionRevision ?? 0
        userNotes = transcription.userNotes
        language = transcription.language
        engine = transcription.engine
        engineVariant = transcription.engineVariant
        calendarEventSnapshot = transcription.calendarEventSnapshot
        meetingCaptureReport = transcription.meetingCaptureReport
        sourceURL = transcription.sourceURL
        sourceType = transcription.sourceType
        recoveredFromCrash = transcription.recoveredFromCrash
        isTranscriptEdited = transcription.isTranscriptEdited
        startContext = transcription.meetingStartContext
    }
}

private struct MeetingArtifactTranscriptSegment: Codable {
    let id: UUID
    let startMs: Int
    let endMs: Int
    let text: String
    let speakerId: String?
    let speakerLabel: String?
    let wordRange: TranscriptSegmentWordRange
    let speakerSpans: [MeetingArtifactSpeakerSpan]?

    init(
        _ segment: TranscriptSegmentRecord,
        speakerRuns: [EffectiveSpeakerRun]?,
        labelsBySpeakerID: [String: String]
    ) {
        id = segment.id
        startMs = segment.startMs
        endMs = segment.endMs
        text = segment.text
        speakerId = segment.speakerId
        speakerLabel = segment.speakerLabel
        wordRange = segment.wordRange
        speakerSpans = speakerRuns?.map {
            MeetingArtifactSpeakerSpan(
                run: $0,
                labelsBySpeakerID: labelsBySpeakerID
            )
        }
    }
}

private struct MeetingArtifactSpeakerSpan: Codable {
    let wordRange: TranscriptSegmentWordRange
    let speakerId: String?
    let speakerLabel: String

    init(run: EffectiveSpeakerRun, labelsBySpeakerID: [String: String]) {
        wordRange = run.wordRange
        switch run.assignment {
        case .speaker(let id):
            speakerId = id
            speakerLabel = labelsBySpeakerID[id] ?? id
        case .unassigned:
            speakerId = nil
            speakerLabel = "Unassigned"
        }
    }
}

private struct MeetingArtifactPromptResult: Codable {
    let index: Int
    let id: UUID
    let name: String
    let promptContent: String
    let extraInstructions: String?
    let content: String
    let userNotesSnapshot: String?
    let includeMeetingNotesSnapshot: Bool
    let inferenceSettingsSnapshot: PromptInferenceSettings?
    let createdAt: Date
    let updatedAt: Date

    init(_ result: PromptResult, index: Int) {
        self.index = index
        id = result.id
        name = result.promptName
        promptContent = result.promptContent
        extraInstructions = result.extraInstructions
        content = result.content
        userNotesSnapshot = result.userNotesSnapshot
        includeMeetingNotesSnapshot = result.includeMeetingNotesSnapshot
        inferenceSettingsSnapshot = result.inferenceSettingsSnapshot
        createdAt = result.createdAt
        updatedAt = result.updatedAt
    }

    func markdown(meetingTitle: String) -> String {
        var sections: [String] = []
        sections.append("# \(name)")
        sections.append("""
        - Meeting: \(meetingTitle)
        - Result ID: \(id.uuidString)
        - Created: \(Self.isoString(createdAt))
        - Automatic meeting notes context: \(includeMeetingNotesSnapshot ? "enabled" : "disabled")
        """)
        sections.append("## Output\n\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))")
        if let extra = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            sections.append("## Extra Instructions\n\n\(extra)")
        }
        sections.append("## Prompt\n\n\(promptContent.trimmingCharacters(in: .whitespacesAndNewlines))")
        if let notes = userNotesSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            sections.append("## User Notes Snapshot\n\n\(notes)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private struct MeetingArtifactPromptResultFile: Codable {
    let id: UUID
    let name: String
    let path: String
}

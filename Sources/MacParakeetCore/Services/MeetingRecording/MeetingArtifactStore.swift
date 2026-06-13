import Foundation

public protocol MeetingArtifactStoring: Sendable {
    @discardableResult
    func materialize(
        transcription: Transcription,
        promptResults: [PromptResult]
    ) async throws -> MeetingArtifactSnapshot
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
    public let transcriptPath: String
    public let notesPath: String?
    public let promptResultsPath: String
    public let promptResultsDirectoryPath: String
    public let promptResultCount: Int

    public init(
        schema: String = MeetingArtifactStore.schema,
        schemaVersion: Int = MeetingArtifactStore.schemaVersion,
        generatedAt: Date,
        meetingID: UUID,
        title: String,
        folderPath: String,
        manifestPath: String,
        transcriptPath: String,
        notesPath: String?,
        promptResultsPath: String,
        promptResultsDirectoryPath: String,
        promptResultCount: Int
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.meetingID = meetingID
        self.title = title
        self.folderPath = folderPath
        self.manifestPath = manifestPath
        self.transcriptPath = transcriptPath
        self.notesPath = notesPath
        self.promptResultsPath = promptResultsPath
        self.promptResultsDirectoryPath = promptResultsDirectoryPath
        self.promptResultCount = promptResultCount
    }
}

public final class MeetingArtifactStore: MeetingArtifactStoring, @unchecked Sendable {
    public static let schema = "com.macparakeet.meeting-session"
    public static let schemaVersion = 1
    public static let manifestFileName = "manifest.json"
    public static let transcriptFileName = "transcript.json"
    public static let promptResultsFileName = "prompt-results.json"
    public static let promptResultsDirectoryName = "prompt-results"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func materialize(
        transcription: Transcription,
        promptResults: [PromptResult] = []
    ) async throws -> MeetingArtifactSnapshot {
        guard transcription.sourceType == .meeting else {
            throw MeetingArtifactError.notMeeting
        }
        guard let folderURL = Self.sessionFolderURL(for: transcription) else {
            throw MeetingArtifactError.missingSessionFolder
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let generatedAt = Date()
        let transcriptURL = folderURL.appendingPathComponent(Self.transcriptFileName)
        let promptResultsURL = folderURL.appendingPathComponent(Self.promptResultsFileName)
        let promptResultsDirectoryURL = folderURL.appendingPathComponent(Self.promptResultsDirectoryName, isDirectory: true)
        let notesURL = MeetingNotesFile.fileURL(for: folderURL)

        let notesPath: String?
        try await MeetingNotesFile.write(
            notes: transcription.userNotes,
            displayName: transcription.fileName,
            to: folderURL,
            fileManager: MeetingNotesFile.SendableFileManager(fileManager)
        )
        notesPath = fileManager.fileExists(atPath: notesURL.path) ? notesURL.path : nil

        let resultFiles = try writePromptResults(
            promptResults,
            meeting: transcription,
            jsonURL: promptResultsURL,
            directoryURL: promptResultsDirectoryURL
        )

        try writeJSON(
            MeetingArtifactTranscript(transcription),
            to: transcriptURL
        )

        let manifestURL = folderURL.appendingPathComponent(Self.manifestFileName)
        let snapshot = MeetingArtifactSnapshot(
            generatedAt: generatedAt,
            meetingID: transcription.id,
            title: transcription.fileName,
            folderPath: folderURL.path,
            manifestPath: manifestURL.path,
            transcriptPath: transcriptURL.path,
            notesPath: notesPath,
            promptResultsPath: promptResultsURL.path,
            promptResultsDirectoryPath: promptResultsDirectoryURL.path,
            promptResultCount: promptResults.count
        )
        try writeJSON(
            MeetingArtifactManifest(
                snapshot: snapshot,
                transcription: transcription,
                promptResultFiles: resultFiles
            ),
            to: manifestURL
        )

        return snapshot
    }

    public static func sessionFolderURL(for transcription: Transcription) -> URL? {
        guard let filePath = transcription.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: filePath).deletingLastPathComponent()
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
                "\(String(format: "%02d", record.index))-\(Self.sanitizedFileName(record.name)).md"
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
        promptResultFiles: [MeetingArtifactPromptResultFile]
    ) {
        schema = snapshot.schema
        schemaVersion = snapshot.schemaVersion
        generatedAt = snapshot.generatedAt
        meeting = MeetingArtifactMeetingSummary(transcription)
        files = MeetingArtifactFiles(snapshot: snapshot, transcription: transcription)
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
    let recoveredFromCrash: Bool
    let isTranscriptEdited: Bool

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
        recoveredFromCrash = transcription.recoveredFromCrash
        isTranscriptEdited = transcription.isTranscriptEdited
    }
}

private struct MeetingArtifactFiles: Codable {
    let folderPath: String
    let mixedAudioPath: String?
    let microphoneAudioPath: String?
    let systemAudioPath: String?
    let metadataPath: String?
    let manifestPath: String
    let transcriptPath: String
    let notesPath: String?
    let promptResultsPath: String
    let promptResultsDirectoryPath: String

    init(snapshot: MeetingArtifactSnapshot, transcription: Transcription) {
        folderPath = snapshot.folderPath
        mixedAudioPath = transcription.filePath
        let folderURL = URL(fileURLWithPath: snapshot.folderPath, isDirectory: true)
        let microphoneURL = folderURL.appendingPathComponent("microphone.m4a")
        let systemURL = folderURL.appendingPathComponent("system.m4a")
        let metadataURL = MeetingRecordingMetadataStore.metadataURL(for: folderURL)
        let fileManager = FileManager.default
        microphoneAudioPath = fileManager.fileExists(atPath: microphoneURL.path) ? microphoneURL.path : nil
        systemAudioPath = fileManager.fileExists(atPath: systemURL.path) ? systemURL.path : nil
        metadataPath = fileManager.fileExists(atPath: metadataURL.path) ? metadataURL.path : nil
        manifestPath = snapshot.manifestPath
        transcriptPath = snapshot.transcriptPath
        notesPath = snapshot.notesPath
        promptResultsPath = snapshot.promptResultsPath
        promptResultsDirectoryPath = snapshot.promptResultsDirectoryPath
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
    let userNotes: String?
    let language: String?
    let engine: String?
    let engineVariant: String?
    let sourceURL: String?
    let sourceType: Transcription.SourceType
    let recoveredFromCrash: Bool
    let isTranscriptEdited: Bool

    init(_ transcription: Transcription) {
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
        userNotes = transcription.userNotes
        language = transcription.language
        engine = transcription.engine
        engineVariant = transcription.engineVariant
        sourceURL = transcription.sourceURL
        sourceType = transcription.sourceType
        recoveredFromCrash = transcription.recoveredFromCrash
        isTranscriptEdited = transcription.isTranscriptEdited
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

import ArgumentParser
import Foundation
import MacParakeetCore

struct MeetingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meetings",
        abstract: "Inspect and manage local meeting recordings.",
        subcommands: [
            ListSubcommand.self,
            ShowSubcommand.self,
            TranscriptSubcommand.self,
            NotesSubcommand.self,
            ResultsSubcommand.self,
            ExportSubcommand.self,
        ]
    )

    struct ListSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List recent meeting recordings."
        )

        @Option(name: .shortAndLong, help: "Maximum number of meetings.")
        var limit: Int = 20

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            guard limit >= 0 else { throw ValidationError("--limit must be >= 0.") }
        }

        func run() async throws {
            try emitJSONOrRethrow(json: json) {
                let repo = try makeTranscriptionRepository(database: database)
                let meetings = try repo.fetchLibraryPage(query: TranscriptionLibraryQuery(
                    sourceType: .meeting,
                    limit: limit,
                    includeProcessing: true
                )).items
                    .map(MeetingListItem.init)

                if json {
                    try printJSON(meetings)
                    return
                }

                guard !meetings.isEmpty else {
                    print("No meetings found.")
                    return
                }

                for meeting in meetings {
                    let duration = meeting.durationMs.map(formatDuration) ?? "--"
                    let notes = meeting.hasNotes ? "notes" : "no notes"
                    print("[\(formatDate(meeting.createdAt))] \(meeting.title) (\(duration)) [\(meeting.status)] [\(notes)]  (\(meeting.shortID))")
                }
            }
        }
    }

    struct ShowSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a local meeting object."
        )

        @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
        var meeting: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try emitJSONOrRethrow(json: json) {
                let repo = try makeTranscriptionRepository(database: database)
                let transcription = try findMeeting(idOrName: meeting, repo: repo)
                let record = MeetingRecord(transcription)

                if json {
                    try printJSON(record)
                    return
                }

                printMeetingRecord(record)
            }
        }
    }

    struct TranscriptSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "transcript",
            abstract: "Print a meeting transcript."
        )

        @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
        var meeting: String

        @Option(name: .shortAndLong, help: "Output format: text, json, srt, vtt.")
        var format: MeetingTranscriptFormat = .text

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try await emitJSONOrRethrow(json: format == .json) {
                let repo = try makeTranscriptionRepository(database: database)
                let transcription = try findMeeting(idOrName: meeting, repo: repo)
                let exportService = await ExportService()

                switch format {
                case .text:
                    print(preferredTranscriptText(transcription))
                case .json:
                    try printJSON(MeetingTranscriptRecord(transcription))
                case .srt:
                    print(await exportService.formatSRT(transcription: transcription))
                case .vtt:
                    print(await exportService.formatVTT(transcription: transcription))
                }
            }
        }
    }

    struct NotesSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "notes",
            abstract: "Read or update local meeting notes.",
            subcommands: [
                GetSubcommand.self,
                SetSubcommand.self,
                AppendSubcommand.self,
                ClearSubcommand.self,
            ]
        )

        struct GetSubcommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "get")

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Flag(name: .long, help: "Emit JSON instead of plain text.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() async throws {
                try emitJSONOrRethrow(json: json) {
                    let repo = try makeTranscriptionRepository(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repo)
                    let envelope = MeetingNotesRecord(transcription)

                    if json {
                        try printJSON(envelope)
                    } else {
                        print(envelope.notes ?? "")
                    }
                }
            }
        }

        struct SetSubcommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set")

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Notes text to store.")
            var text: String?

            @Flag(name: .long, help: "Read notes text from stdin.")
            var stdin: Bool = false

            @Flag(name: .long, help: "Emit the updated notes object as JSON.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                if text != nil && stdin {
                    throw ValidationError("Use either --text or --stdin, not both.")
                }
                if text == nil && !stdin {
                    throw ValidationError("Pass --text or --stdin.")
                }
            }

            func run() async throws {
                try emitJSONOrRethrow(json: json) {
                    let repo = try makeTranscriptionRepository(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repo)
                    let notes = try notesInput(text: text, stdin: stdin)
                    try repo.updateUserNotes(id: transcription.id, userNotes: normalizedNotes(notes))
                    let updated = try repo.fetch(id: transcription.id) ?? transcription
                    try emitNotesUpdate(MeetingNotesRecord(updated), json: json)
                }
            }
        }

        struct AppendSubcommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "append")

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Notes text to append.")
            var text: String?

            @Flag(name: .long, help: "Read notes text from stdin.")
            var stdin: Bool = false

            @Flag(name: .long, help: "Emit the updated notes object as JSON.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                if text != nil && stdin {
                    throw ValidationError("Use either --text or --stdin, not both.")
                }
                if text == nil && !stdin {
                    throw ValidationError("Pass --text or --stdin.")
                }
            }

            func run() async throws {
                try emitJSONOrRethrow(json: json) {
                    let repo = try makeTranscriptionRepository(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repo)
                    let addition = try notesInput(text: text, stdin: stdin)
                    let combined = appendedNotes(existing: transcription.userNotes, addition: addition)
                    try repo.updateUserNotes(id: transcription.id, userNotes: normalizedNotes(combined))
                    let updated = try repo.fetch(id: transcription.id) ?? transcription
                    try emitNotesUpdate(MeetingNotesRecord(updated), json: json)
                }
            }
        }

        struct ClearSubcommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "clear")

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Flag(name: .long, help: "Emit the updated notes object as JSON.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() async throws {
                try emitJSONOrRethrow(json: json) {
                    let repo = try makeTranscriptionRepository(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repo)
                    try repo.updateUserNotes(id: transcription.id, userNotes: nil)
                    let updated = try repo.fetch(id: transcription.id) ?? transcription
                    try emitNotesUpdate(MeetingNotesRecord(updated), json: json)
                }
            }
        }
    }

    struct ResultsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "results",
            abstract: "Read or write saved prompt results for meetings.",
            subcommands: [
                ListSubcommand.self,
                AddSubcommand.self,
            ]
        )

        struct ListSubcommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List saved PromptResults for a meeting."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() async throws {
                try emitJSONOrRethrow(json: json) {
                    let repositories = try makeMeetingResultRepositories(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                    let results = try repositories.promptResults
                        .fetchAll(transcriptionId: transcription.id)
                        .map { MeetingPromptResultRecord(result: $0, transcription: transcription) }

                    if json {
                        try printJSON(results)
                        return
                    }

                    guard !results.isEmpty else {
                        print("No prompt results found for \(transcription.fileName).")
                        return
                    }

                    for result in results {
                        let previewText = preview(result.content, maxLength: 80) ?? ""
                        print("\(result.shortID)  \(result.name)  \(formatDate(result.createdAt))  \(previewText)")
                    }
                    print()
                    print("\(results.count) result(s)")
                }
            }
        }

        struct AddSubcommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "add",
                abstract: "Store externally generated output as a PromptResult for a meeting."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Display name for the saved result.")
            var name: String

            @Option(name: .long, help: "Generated result content to store.")
            var content: String?

            @Flag(name: .long, help: "Read generated result content from stdin.")
            var stdin: Bool = false

            @Option(name: .long, help: "Prompt or instructions that produced this result.")
            var promptContent: String?

            @Option(name: .long, help: "Extra instructions or provenance to store with the result.")
            var extra: String?

            @Flag(name: .long, help: "Emit the saved result object as JSON.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                if content != nil && stdin {
                    throw ValidationError("Use either --content or --stdin, not both.")
                }
                if content == nil && !stdin {
                    throw ValidationError("Pass --content or --stdin.")
                }
                if normalizedNonEmptyText(name) == nil {
                    throw ValidationError("--name must not be empty.")
                }
            }

            func run() async throws {
                try emitJSONOrRethrow(json: json) {
                    let repositories = try makeMeetingResultRepositories(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                    let resultContent = try resultInput(content: content, stdin: stdin)
                    guard let resultName = normalizedNonEmptyText(name) else {
                        throw ValidationError("--name must not be empty.")
                    }
                    let promptSnapshot = normalizedNonEmptyText(promptContent)
                        ?? "External result imported with `macparakeet-cli meetings results add`."
                    let now = Date()
                    let promptResult = PromptResult(
                        transcriptionId: transcription.id,
                        promptName: resultName,
                        promptContent: promptSnapshot,
                        extraInstructions: normalizedNonEmptyText(extra),
                        content: resultContent,
                        userNotesSnapshot: transcription.userNotes,
                        createdAt: now,
                        updatedAt: now
                    )

                    try repositories.promptResults.save(promptResult)
                    let record = MeetingPromptResultRecord(result: promptResult, transcription: transcription)
                    if json {
                        try printJSON(record)
                    } else {
                        print("Saved PromptResult \(record.shortID) for \(transcription.fileName).")
                    }
                }
            }
        }
    }

    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export a deterministic local meeting artifact."
        )

        @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
        var meeting: String

        @Option(name: .shortAndLong, help: "Output format: md, json.")
        var format: MeetingExportFormat = .md

        @Option(name: .shortAndLong, help: "Output file path (defaults to current directory with auto-generated name).")
        var output: String?

        @Flag(help: "Print to stdout instead of writing a file.")
        var stdout: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try emitJSONOrRethrow(json: stdout && format == .json) {
                let repo = try makeTranscriptionRepository(database: database)
                let transcription = try findMeeting(idOrName: meeting, repo: repo)
                let content = try exportContent(for: transcription, format: format)

                if stdout {
                    print(content)
                    return
                }

                let outputURL = resolvedOutputURL(output, transcription: transcription, fileExtension: format.fileExtension)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try content.write(to: outputURL, atomically: true, encoding: .utf8)
                print("Exported to \(outputURL.path)")
            }
        }
    }
}

enum MeetingTranscriptFormat: String, ExpressibleByArgument {
    case text
    case json
    case srt
    case vtt
}

enum MeetingExportFormat: String, ExpressibleByArgument {
    case md
    case json

    var fileExtension: String { rawValue }
}

private struct MeetingListItem: Encodable {
    let id: UUID
    let shortID: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let durationMs: Int?
    let status: Transcription.TranscriptionStatus
    let isFavorite: Bool
    let hasNotes: Bool
    let notesPreview: String?
    let hasTranscript: Bool
    let transcriptPreview: String?

    init(_ transcription: Transcription) {
        id = transcription.id
        shortID = String(transcription.id.uuidString.prefix(8))
        title = transcription.fileName
        createdAt = transcription.createdAt
        updatedAt = transcription.updatedAt
        durationMs = transcription.durationMs
        status = transcription.status
        isFavorite = transcription.isFavorite
        hasNotes = normalizedNotes(transcription.userNotes) != nil
        notesPreview = preview(transcription.userNotes)
        let transcript = preferredTranscriptText(transcription)
        hasTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        transcriptPreview = preview(transcript)
    }
}

private struct MeetingRecord: Encodable {
    let id: UUID
    let shortID: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let durationMs: Int?
    let status: Transcription.TranscriptionStatus
    let isFavorite: Bool
    let filePath: String?
    let recoveredFromCrash: Bool
    let isTranscriptEdited: Bool
    let notes: String?
    let rawTranscript: String?
    let cleanTranscript: String?
    let transcript: String
    let wordTimestamps: [WordTimestamp]?
    let speakerCount: Int?
    let speakers: [SpeakerInfo]?
    let diarizationSegments: [DiarizationSegmentRecord]?

    init(_ transcription: Transcription) {
        id = transcription.id
        shortID = String(transcription.id.uuidString.prefix(8))
        title = transcription.fileName
        createdAt = transcription.createdAt
        updatedAt = transcription.updatedAt
        durationMs = transcription.durationMs
        status = transcription.status
        isFavorite = transcription.isFavorite
        filePath = transcription.filePath
        recoveredFromCrash = transcription.recoveredFromCrash
        isTranscriptEdited = transcription.isTranscriptEdited
        notes = transcription.userNotes
        rawTranscript = transcription.rawTranscript
        cleanTranscript = transcription.cleanTranscript
        transcript = preferredTranscriptText(transcription)
        wordTimestamps = transcription.wordTimestamps
        speakerCount = transcription.speakerCount
        speakers = transcription.speakers
        diarizationSegments = transcription.diarizationSegments
    }
}

private struct MeetingTranscriptRecord: Encodable {
    let id: UUID
    let title: String
    let rawTranscript: String?
    let cleanTranscript: String?
    let transcript: String
    let wordTimestamps: [WordTimestamp]?
    let speakers: [SpeakerInfo]?

    init(_ transcription: Transcription) {
        id = transcription.id
        title = transcription.fileName
        rawTranscript = transcription.rawTranscript
        cleanTranscript = transcription.cleanTranscript
        transcript = preferredTranscriptText(transcription)
        wordTimestamps = transcription.wordTimestamps
        speakers = transcription.speakers
    }
}

private struct MeetingNotesRecord: Encodable {
    let id: UUID
    let title: String
    let notes: String?
    let hasNotes: Bool
    let updatedAt: Date

    init(_ transcription: Transcription) {
        id = transcription.id
        title = transcription.fileName
        notes = transcription.userNotes
        hasNotes = normalizedNotes(transcription.userNotes) != nil
        updatedAt = transcription.updatedAt
    }
}

private struct MeetingPromptResultRecord: Encodable {
    let id: UUID
    let shortID: String
    let meetingId: UUID
    let meetingTitle: String
    let name: String
    let promptContent: String
    let extraInstructions: String?
    let content: String
    let userNotesSnapshot: String?
    let createdAt: Date
    let updatedAt: Date

    init(result: PromptResult, transcription: Transcription) {
        id = result.id
        shortID = String(result.id.uuidString.prefix(8))
        meetingId = transcription.id
        meetingTitle = transcription.fileName
        name = result.promptName
        promptContent = result.promptContent
        extraInstructions = result.extraInstructions
        content = result.content
        userNotesSnapshot = result.userNotesSnapshot
        createdAt = result.createdAt
        updatedAt = result.updatedAt
    }
}

private struct MeetingResultRepositories {
    let transcriptions: TranscriptionRepository
    let promptResults: PromptResultRepository
}

private func makeDatabaseManager(database: String?) throws -> DatabaseManager {
    try AppPaths.ensureDirectories()
    return try DatabaseManager(path: resolvedDatabasePath(database))
}

private func makeMeetingResultRepositories(database: String?) throws -> MeetingResultRepositories {
    let dbManager = try makeDatabaseManager(database: database)
    return MeetingResultRepositories(
        transcriptions: TranscriptionRepository(dbQueue: dbManager.dbQueue),
        promptResults: PromptResultRepository(dbQueue: dbManager.dbQueue)
    )
}

private func makeTranscriptionRepository(database: String?) throws -> TranscriptionRepository {
    let dbManager = try makeDatabaseManager(database: database)
    return TranscriptionRepository(dbQueue: dbManager.dbQueue)
}

private func preferredTranscriptText(_ transcription: Transcription) -> String {
    transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
}

private func normalizedNotes(_ value: String?) -> String? {
    guard let value, normalizedNonEmptyText(value) != nil else { return nil }
    return value
}

private func normalizedNonEmptyText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty
    else {
        return nil
    }
    return trimmed
}

private func preview(_ value: String?, maxLength: Int = 120) -> String? {
    guard let value = normalizedNotes(value) else { return nil }
    let compact = value
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard !compact.isEmpty else { return nil }
    if compact.count <= maxLength { return compact }
    let end = compact.index(compact.startIndex, offsetBy: maxLength)
    return String(compact[..<end]) + "..."
}

private func notesInput(text: String?, stdin: Bool) throws -> String {
    let value: String
    if stdin {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw CLIInputError.invalidEncoding
        }
        value = decoded
    } else {
        value = text ?? ""
    }
    guard normalizedNotes(value) != nil else { throw CLIInputError.empty }
    return value
}

private func resultInput(content: String?, stdin: Bool) throws -> String {
    let value: String
    if stdin {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw CLIInputError.invalidEncoding
        }
        value = decoded
    } else {
        value = content ?? ""
    }
    guard normalizedNonEmptyText(value) != nil else { throw CLIInputError.empty }
    return value
}

private func appendedNotes(existing: String?, addition: String) -> String {
    guard let existing = normalizedNotes(existing) else { return addition }
    return existing + "\n" + addition
}

private func emitNotesUpdate(_ record: MeetingNotesRecord, json: Bool) throws {
    if json {
        try printJSON(record)
    } else if record.hasNotes {
        print("Updated notes for \(record.title).")
    } else {
        print("Cleared notes for \(record.title).")
    }
}

private func exportContent(for transcription: Transcription, format: MeetingExportFormat) throws -> String {
    switch format {
    case .md:
        return markdownExport(for: transcription)
    case .json:
        let data = try cliJSONEncoder.encode(MeetingRecord(transcription))
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private func markdownExport(for transcription: Transcription) -> String {
    var sections: [String] = []
    sections.append("# \(transcription.fileName)")
    sections.append("""
    - ID: \(transcription.id.uuidString)
    - Created: \(ISO8601DateFormatter().string(from: transcription.createdAt))
    - Duration: \(transcription.durationMs.map(formatDuration) ?? "--")
    - Status: \(transcription.status.rawValue)
    """)

    if let notes = normalizedNotes(transcription.userNotes) {
        sections.append("## Notes\n\n\(notes)")
    }

    let transcript = preferredTranscriptText(transcription)
    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sections.append("## Transcript\n\n\(transcript)")
    }

    return sections.joined(separator: "\n\n") + "\n"
}

private func printMeetingRecord(_ record: MeetingRecord) {
    print(record.title)
    print("ID: \(record.id.uuidString)")
    print("Created: \(formatDate(record.createdAt))")
    print("Duration: \(record.durationMs.map(formatDuration) ?? "--")")
    print("Status: \(record.status.rawValue)")
    if let filePath = record.filePath {
        print("Audio: \(filePath)")
    }

    if let notes = normalizedNotes(record.notes) {
        print("\nNotes:\n\(notes)")
    }

    if !record.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        print("\nTranscript:\n\(record.transcript)")
    }
}

private func resolvedOutputURL(_ output: String?, transcription: Transcription, fileExtension: String) -> URL {
    if let output {
        return URL(fileURLWithPath: expandTilde(output))
    }
    let baseName = sanitizedFileName(URL(fileURLWithPath: transcription.fileName).deletingPathExtension().lastPathComponent)
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("\(baseName).\(fileExtension)")
}

private func sanitizedFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:")
    let cleaned = value
        .components(separatedBy: invalid)
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "meeting" : cleaned
}

private func formatDate(_ date: Date) -> String {
    date.formatted(date: .numeric, time: .shortened)
}

private func formatDuration(_ durationMs: Int) -> String {
    let totalSeconds = max(0, durationMs / 1000)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return "\(hours)h \(minutes)m \(seconds)s"
    }
    return "\(minutes)m \(seconds)s"
}

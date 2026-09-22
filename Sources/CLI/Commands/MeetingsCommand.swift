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
            CorrectionsSubcommand.self,
            NotesSubcommand.self,
            ResultsSubcommand.self,
            TypesSubcommand.self,
            LabelsSubcommand.self,
            ClassifySubcommand.self,
            ArtifactSubcommand.self,
            ExportSubcommand.self,
            SplitSubcommand.self,
            ImportSubcommand.self,
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

        @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
        var envelope: Bool = false

        @Option(name: .long, help: "Meeting type UUID, prefix, or exact name; repeatable (ANY).")
        var type: [String] = []

        @Option(name: .long, help: "Meeting label UUID, prefix, or exact name; repeatable (ANY).")
        var label: [String] = []

        @Flag(name: .long, help: "List only meetings without a primary type.")
        var unclassified = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            guard limit >= 0 else { throw ValidationError("--limit must be >= 0.") }
            if unclassified && !type.isEmpty {
                throw ValidationError("--unclassified and --type are mutually exclusive")
            }
            try validateJSONEnvelopeFlags(json: json, envelope: envelope)
        }

        func run() async throws {
            try emitJSONOrRethrow(json: json || envelope) {
                let repositories = try makeMeetingResultRepositories(database: database)
                let typeRepo = MeetingTypeRepository(dbQueue: repositories.database.dbQueue)
                let labelRepo = MeetingLabelRepository(dbQueue: repositories.database.dbQueue)
                let typeIDs = try Set(type.map {
                    try findMeetingType($0, repo: typeRepo, includeArchived: true).id
                })
                let labelIDs = try Set(label.map {
                    try findMeetingLabel($0, repo: labelRepo, includeArchived: true).id
                })
                let page = try repositories.transcriptions.fetchLibraryPage(
                    query: TranscriptionLibraryQuery(
                        sourceType: .meeting,
                        meetingTypeIDs: typeIDs,
                        unclassifiedMeetingsOnly: unclassified,
                        meetingLabelIDs: labelIDs,
                        limit: limit,
                        includeProcessing: true
                    )
                )
                let meetings = page.items
                let promptResultCounts = try repositories.promptResults.counts(
                    transcriptionIds: meetings.map(\.id)
                )
                let classificationService = MeetingClassificationService(dbQueue: repositories.database.dbQueue)
                let items = try meetings.map { transcription in
                    return MeetingListItem(
                        transcription,
                        effectiveTranscriptText: page.effectiveTranscriptTextByID[transcription.id],
                        promptResultCount: promptResultCounts[transcription.id] ?? 0,
                        classification: try classificationService.classification(for: transcription.id)
                    )
                }

                if envelope {
                    try printEnvelope(command: "meetings list", data: items)
                    return
                }
                if json {
                    try printJSON(items)
                    return
                }

                guard !items.isEmpty else {
                    print("No meetings found.")
                    return
                }

                for meeting in items {
                    let duration = meeting.durationMs.map(formatDuration) ?? "--"
                    let notes = meeting.hasNotes ? "notes" : "no notes"
                    let results = meeting.promptResultCount == 1 ? "1 result" : "\(meeting.promptResultCount) results"
                    print(
                        "[\(formatDate(meeting.createdAt))] \(meeting.title) (\(duration)) [\(meeting.status)] [\(notes)] [\(results)]  (\(meeting.shortID))"
                    )
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

        @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
        var envelope: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            try validateJSONEnvelopeFlags(json: json, envelope: envelope)
        }

        func run() async throws {
            try emitJSONOrRethrow(json: json || envelope) {
                let repositories = try makeMeetingResultRepositories(database: database)
                let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                let projection = try repositories.speakerAttributionReader.resolve(transcription: transcription)
                let record = MeetingRecord(
                    projection,
                    promptResultCount: try repositories.promptResults.count(transcriptionId: transcription.id),
                    classification: try MeetingClassificationService(dbQueue: repositories.database.dbQueue)
                        .classification(for: transcription.id)
                )

                if envelope {
                    try printEnvelope(command: "meetings show", data: record)
                    return
                }
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
            try emitJSONOrRethrow(json: format == .json) {
                let repositories = try makeMeetingResultRepositories(database: database)
                let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                let projection = try repositories.speakerAttributionReader.resolve(transcription: transcription)
                let exportService = ExportService()

                switch format {
                case .text:
                    print(preferredTranscriptText(projection.effectiveTranscription))
                case .json:
                    let classification = try MeetingClassificationService(dbQueue: repositories.database.dbQueue)
                        .classification(for: transcription.id)
                    try printJSON(MeetingTranscriptRecord(projection, classification: classification))
                case .srt:
                    print(exportService.formatSRT(projection: projection))
                case .vtt:
                    print(exportService.formatVTT(projection: projection))
                }
            }
        }
    }

    struct CorrectionsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "corrections",
            abstract: "Edit timed transcript lines through the reversible correction journal.",
            subcommands: [
                EditLine.self,
                MergeLines.self,
                Rename.self,
                Assign.self,
                MergeSpeakers.self,
                Undo.self,
                Redo.self,
                Reset.self,
            ]
        )

        struct EditLine: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "edit-line",
                abstract: "Replace one timed line while retaining its segment envelope."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Segment UUID from meetings transcript --format json.")
            var segment: String

            @Option(name: .long, help: "Replacement text.")
            var text: String?

            @Flag(name: .long, help: "Read replacement text from stdin.")
            var stdin = false

            @Option(name: .long, help: "Expected speakerCorrectionRevision from the last read.")
            var expectedRevision: Int

            @Flag(name: .long, help: "Emit the updated transcript object as JSON.")
            var json = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                if text != nil && stdin {
                    throw ValidationError("Use either --text or --stdin, not both.")
                }
                if text == nil && !stdin {
                    throw ValidationError("Pass --text or --stdin.")
                }
                guard expectedRevision >= 0 else {
                    throw ValidationError("--expected-revision must be >= 0.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    let replacement = try correctionTextInput(text: text, stdin: stdin)
                    try await runMeetingCorrection(
                        meeting: meeting,
                        expectedRevision: expectedRevision,
                        database: database,
                        json: json,
                        envelope: envelope,
                        commandName: "meetings corrections edit-line"
                    ) { projection in
                        .editText(
                            target: try correctionTarget(segment: segment, in: projection),
                            text: replacement
                        )
                    }
                }
            }
        }

        struct MergeLines: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "merge-lines",
                abstract: "Merge adjacent same-speaker timed lines."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Segment UUID in transcript order; repeat at least twice.")
            var segment: [String] = []

            @Option(name: .long, help: "Expected speakerCorrectionRevision from the last read.")
            var expectedRevision: Int

            @Flag(name: .long, help: "Emit the updated transcript object as JSON.")
            var json = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                guard segment.count >= 2 else {
                    throw ValidationError("Pass --segment at least twice.")
                }
                guard expectedRevision >= 0 else {
                    throw ValidationError("--expected-revision must be >= 0.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    try await runMeetingCorrection(
                        meeting: meeting,
                        expectedRevision: expectedRevision,
                        database: database,
                        json: json,
                        envelope: envelope,
                        commandName: "meetings corrections merge-lines"
                    ) { projection in
                        .mergeSegments(
                            targets: try segment.map { try correctionTarget(segment: $0, in: projection) }
                        )
                    }
                }
            }
        }

        struct Rename: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "rename",
                abstract: "Rename one speaker in the reversible correction journal."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Speaker id from meetings transcript --format json.")
            var speaker: String

            @Option(name: .long, help: "New display label.")
            var label: String

            @Option(name: .long, help: "Expected speakerCorrectionRevision from the last read.")
            var expectedRevision: Int

            @Flag(name: .long, help: "Emit the updated transcript object as JSON.")
            var json = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                guard !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("--speaker must not be empty.")
                }
                guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("--label must not be empty.")
                }
                guard expectedRevision >= 0 else {
                    throw ValidationError("--expected-revision must be >= 0.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    try await runMeetingCorrection(
                        meeting: meeting,
                        expectedRevision: expectedRevision,
                        database: database,
                        json: json,
                        envelope: envelope,
                        commandName: "meetings corrections rename"
                    ) { projection in
                        let speakerID = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        // An unchanged label is not a rename. Applying it would
                        // still insert a journal row and advance revision, then
                        // break callers holding `--expected-revision`.
                        if let current = projection.attribution.speakers.first(where: { $0.id == speakerID }),
                            current.label == trimmedLabel
                        {
                            return nil
                        }
                        return .rename(speakerID: speakerID, label: trimmedLabel)
                    }
                }
            }
        }

        struct Assign: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "assign",
                abstract: "Assign one or more timed lines to a speaker or unassigned."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Segment UUID from meetings transcript --format json; repeatable.")
            var segment: [String] = []

            @Option(name: .long, help: "Existing speaker id to assign the lines to.")
            var toSpeaker: String?

            @Flag(name: .long, help: "Clear speaker assignment on the selected lines.")
            var unassigned = false

            @Option(name: .long, help: "Expected speakerCorrectionRevision from the last read.")
            var expectedRevision: Int

            @Flag(name: .long, help: "Emit the updated transcript object as JSON.")
            var json = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                guard !segment.isEmpty else {
                    throw ValidationError("Pass --segment at least once.")
                }
                if toSpeaker != nil && unassigned {
                    throw ValidationError("Use either --to-speaker or --unassigned, not both.")
                }
                if toSpeaker == nil && !unassigned {
                    throw ValidationError("Pass --to-speaker or --unassigned.")
                }
                if let toSpeaker, toSpeaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("--to-speaker must not be empty.")
                }
                guard expectedRevision >= 0 else {
                    throw ValidationError("--expected-revision must be >= 0.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    let assignment: SpeakerAssignment = if unassigned {
                        .unassigned
                    } else {
                        .speaker(id: toSpeaker!.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    try await runMeetingCorrection(
                        meeting: meeting,
                        expectedRevision: expectedRevision,
                        database: database,
                        json: json,
                        envelope: envelope,
                        commandName: "meetings corrections assign"
                    ) { projection in
                        .assign(
                            targets: try segment.map { try correctionTarget(segment: $0, in: projection) },
                            to: assignment
                        )
                    }
                }
            }
        }

        struct MergeSpeakers: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "merge-speakers",
                abstract: "Merge one speaker into another."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Speaker id whose lines should move.")
            var from: String

            @Option(name: .long, help: "Speaker id that should remain.")
            var into: String

            @Option(name: .long, help: "Expected speakerCorrectionRevision from the last read.")
            var expectedRevision: Int

            @Flag(name: .long, help: "Emit the updated transcript object as JSON.")
            var json = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                guard !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("--from must not be empty.")
                }
                guard !into.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("--into must not be empty.")
                }
                guard from.trimmingCharacters(in: .whitespacesAndNewlines)
                    != into.trimmingCharacters(in: .whitespacesAndNewlines)
                else {
                    throw ValidationError("--from and --into must be different speakers.")
                }
                guard expectedRevision >= 0 else {
                    throw ValidationError("--expected-revision must be >= 0.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    try await runMeetingCorrection(
                        meeting: meeting,
                        expectedRevision: expectedRevision,
                        database: database,
                        json: json,
                        envelope: envelope,
                        commandName: "meetings corrections merge-speakers"
                    ) { _ in
                        .merge(
                            sourceSpeakerID: from.trimmingCharacters(in: .whitespacesAndNewlines),
                            targetSpeakerID: into.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                }
            }
        }

        struct Undo: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "undo",
                abstract: "Undo the active transcript correction."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Expected speakerCorrectionRevision from the last transcript read.")
            var expectedRevision: Int

            @Flag(name: .long, help: "Emit the updated transcript object as JSON.")
            var json = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                guard expectedRevision >= 0 else {
                    throw ValidationError("--expected-revision must be >= 0.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    try await runMeetingCorrectionHistory(
                        .undo, meeting: meeting, expectedRevision: expectedRevision,
                        database: database, json: json, envelope: envelope
                    )
                }
            }
        }

        struct Redo: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "redo",
                abstract: "Redo the next transcript correction."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Expected speakerCorrectionRevision from the last transcript read.")
            var expectedRevision: Int

            @Flag(name: .long, help: "Emit the updated transcript object as JSON.")
            var json = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                guard expectedRevision >= 0 else {
                    throw ValidationError("--expected-revision must be >= 0.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    try await runMeetingCorrectionHistory(
                        .redo, meeting: meeting, expectedRevision: expectedRevision,
                        database: database, json: json, envelope: envelope
                    )
                }
            }
        }

        struct Reset: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "reset",
                abstract: "Reset the active transcript projection to its automatic baseline."
            )

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Option(name: .long, help: "Expected speakerCorrectionRevision from the last transcript read.")
            var expectedRevision: Int

            @Flag(name: .long, help: "Emit the updated transcript object as JSON.")
            var json = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                guard expectedRevision >= 0 else {
                    throw ValidationError("--expected-revision must be >= 0.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    try await runMeetingCorrection(
                        meeting: meeting,
                        expectedRevision: expectedRevision,
                        database: database,
                        json: json,
                        envelope: envelope,
                        commandName: "meetings corrections reset"
                    ) { _ in .reset }
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

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try emitJSONOrRethrow(json: json || envelope) {
                    let repo = try makeTranscriptionRepository(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repo)
                    let envelope = MeetingNotesRecord(transcription)

                    if self.envelope {
                        try printEnvelope(command: "meetings notes get", data: envelope)
                    } else if json {
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

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                if text != nil && stdin {
                    throw ValidationError("Use either --text or --stdin, not both.")
                }
                if text == nil && !stdin {
                    throw ValidationError("Pass --text or --stdin.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    let repositories = try makeMeetingResultRepositories(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                    let notes = try notesInput(text: text, stdin: stdin)
                    try repositories.transcriptions.updateUserNotes(
                        id: transcription.id, userNotes: normalizedNotes(notes))
                    let updated = try repositories.transcriptions.fetch(id: transcription.id) ?? transcription
                    let snapshot = await refreshMeetingArtifactBestEffort(
                        transcription: updated, repositories: repositories)
                    try emitNotesUpdate(
                        MeetingNotesRecord(updated, artifact: snapshot), json: json, envelope: envelope,
                        command: "meetings notes set")
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

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                if text != nil && stdin {
                    throw ValidationError("Use either --text or --stdin, not both.")
                }
                if text == nil && !stdin {
                    throw ValidationError("Pass --text or --stdin.")
                }
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    let repositories = try makeMeetingResultRepositories(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                    let addition = try notesInput(text: text, stdin: stdin)
                    let combined = appendedNotes(existing: transcription.userNotes, addition: addition)
                    try repositories.transcriptions.updateUserNotes(
                        id: transcription.id, userNotes: normalizedNotes(combined))
                    let updated = try repositories.transcriptions.fetch(id: transcription.id) ?? transcription
                    let snapshot = await refreshMeetingArtifactBestEffort(
                        transcription: updated, repositories: repositories)
                    try emitNotesUpdate(
                        MeetingNotesRecord(updated, artifact: snapshot), json: json, envelope: envelope,
                        command: "meetings notes append")
                }
            }
        }

        struct ClearSubcommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "clear")

            @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
            var meeting: String

            @Flag(name: .long, help: "Emit the updated notes object as JSON.")
            var json: Bool = false

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    let repositories = try makeMeetingResultRepositories(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                    try repositories.transcriptions.updateUserNotes(id: transcription.id, userNotes: nil)
                    let updated = try repositories.transcriptions.fetch(id: transcription.id) ?? transcription
                    let snapshot = await refreshMeetingArtifactBestEffort(
                        transcription: updated, repositories: repositories)
                    try emitNotesUpdate(
                        MeetingNotesRecord(updated, artifact: snapshot), json: json, envelope: envelope,
                        command: "meetings notes clear")
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

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try emitJSONOrRethrow(json: json || envelope) {
                    let repositories = try makeMeetingResultRepositories(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                    let results = try repositories.promptResults
                        .fetchAll(transcriptionId: transcription.id)
                        .map { MeetingPromptResultRecord(result: $0, transcription: transcription) }

                    if envelope {
                        try printEnvelope(command: "meetings results list", data: results)
                        return
                    }
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

            @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
            var envelope: Bool = false

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
                try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            }

            func run() async throws {
                try await emitJSONOrRethrow(json: json || envelope) {
                    let repositories = try makeMeetingResultRepositories(database: database)
                    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                    let resultContent = try resultInput(content: content, stdin: stdin)
                    guard let resultName = normalizedNonEmptyText(name) else {
                        throw ValidationError("--name must not be empty.")
                    }
                    let promptSnapshot =
                        normalizedNonEmptyText(promptContent)
                        ?? "External result imported with `macparakeet-cli meetings results add`."
                    let now = Date()
                    let promptResult = PromptResult(
                        transcriptionId: transcription.id,
                        promptName: resultName,
                        promptContent: promptSnapshot,
                        extraInstructions: normalizedNonEmptyText(extra),
                        content: resultContent,
                        // Imported output did not send meeting notes through
                        // MacParakeet, so it has no effective-notes receipt.
                        userNotesSnapshot: nil,
                        includeMeetingNotesSnapshot: false,
                        createdAt: now,
                        updatedAt: now
                    )

                    try repositories.promptResults.save(promptResult)
                    let updatedResults = try repositories.promptResults.fetchAll(transcriptionId: transcription.id)
                    let snapshot = await refreshMeetingArtifactBestEffort(
                        transcription: transcription,
                        promptResults: updatedResults,
                        repositories: repositories
                    )
                    let record = MeetingPromptResultRecord(
                        result: promptResult,
                        transcription: transcription,
                        artifact: snapshot
                    )
                    if envelope {
                        try printEnvelope(command: "meetings results add", data: record)
                    } else if json {
                        try printJSON(record)
                    } else {
                        print("Saved PromptResult \(record.shortID) for \(transcription.fileName).")
                    }
                }
            }
        }
    }

    struct ArtifactSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "artifact",
            abstract: "Materialize and inspect a meeting session artifact folder."
        )

        @Argument(help: "Meeting UUID, UUID prefix, or exact title.")
        var meeting: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
        var envelope: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            try validateJSONEnvelopeFlags(json: json, envelope: envelope)
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json || envelope) {
                let repositories = try makeMeetingResultRepositories(database: database)
                let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                let promptResults = try repositories.promptResults.fetchAll(transcriptionId: transcription.id)
                let classification = try MeetingClassificationService(dbQueue: repositories.database.dbQueue)
                    .classification(for: transcription.id)
                let snapshot = try await materializeMeetingArtifact(
                    transcription: transcription,
                    promptResults: promptResults,
                    classification: classification,
                    speakerAttributionReader: repositories.speakerAttributionReader
                )

                if envelope {
                    try printEnvelope(command: "meetings artifact", data: snapshot)
                } else if json {
                    try printJSON(snapshot)
                } else {
                    print("Artifact folder: \(snapshot.folderPath)")
                    print("Manifest: \(snapshot.manifestPath)")
                    print("Transcript: \(snapshot.transcriptPath)")
                    if let notesPath = snapshot.notesPath {
                        print("Notes: \(notesPath)")
                    }
                    print("Prompt results: \(snapshot.promptResultsPath)")
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
                let repositories = try makeMeetingResultRepositories(database: database)
                let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
                let projection = try repositories.speakerAttributionReader.resolve(transcription: transcription)
                let promptResults = try repositories.promptResults.fetchAll(transcriptionId: transcription.id)
                let classification = try MeetingClassificationService(dbQueue: repositories.database.dbQueue)
                    .classification(for: transcription.id)
                let content = try exportContent(
                    for: projection,
                    format: format,
                    promptResults: promptResults,
                    classification: classification
                )

                if stdout {
                    FileHandle.standardOutput.write(Data(content.utf8))
                    return
                }

                let outputURL = resolvedOutputURL(
                    output, transcription: transcription, fileExtension: format.fileExtension)
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
    let hasPromptResults: Bool
    let promptResultCount: Int
    let hasTranscript: Bool
    let transcriptPreview: String?
    let artifactFolderPath: String?
    let hasArtifactManifest: Bool
    let meetingType: MeetingType?
    let meetingLabels: [MeetingLabel]

    init(
        _ transcription: Transcription,
        effectiveTranscriptText: String? = nil,
        promptResultCount: Int = 0,
        classification: MeetingClassification = MeetingClassification(meetingType: nil, labels: [])
    ) {
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
        self.promptResultCount = promptResultCount
        hasPromptResults = promptResultCount > 0
        let transcript = effectiveTranscriptText ?? preferredTranscriptText(transcription)
        hasTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        transcriptPreview = preview(transcript)
        let artifactFolder = MeetingArtifactStore.sessionFolderURL(for: transcription)
        artifactFolderPath = artifactFolder?.path
        hasArtifactManifest =
            artifactFolder.map {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(MeetingArtifactStore.manifestFileName).path
            )
        } ?? false
        meetingType = classification.meetingType
        meetingLabels = classification.labels
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
    let hasPromptResults: Bool
    let promptResultCount: Int
    let rawTranscript: String?
    let cleanTranscript: String?
    let transcript: String
    let wordTimestamps: [WordTimestamp]?
    let speakerCount: Int?
    let speakers: [SpeakerInfo]?
    let diarizationSegments: [DiarizationSegmentRecord]?
    let transcriptSegments: [TranscriptSegmentRecord]?
    let calendarEventSnapshot: MeetingCalendarSnapshot?
    let artifactFolderPath: String?
    let artifactManifestPath: String?
    let artifactMarkdownPath: String?
    let rawMicrophoneAudioPath: String?
    let cleanedMicrophoneAudioPath: String?
    let rawSystemAudioPath: String?
    let playbackAudioPath: String?
    let hasArtifactManifest: Bool
    let startContext: MeetingStartContext?
    let meetingType: MeetingType?
    let meetingLabels: [MeetingLabel]
    let speakerCorrectionsApplied: Bool
    let textCorrectionsApplied: Bool
    let speakerCorrectionRevision: Int
    let transcriptTextAlignment: TranscriptTextAlignment

    init(
        _ projection: SpeakerAttributionProjection,
        promptResultCount: Int = 0,
        classification: MeetingClassification = MeetingClassification(meetingType: nil, labels: [])
    ) {
        let transcription = projection.effectiveTranscription
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
        self.promptResultCount = promptResultCount
        hasPromptResults = promptResultCount > 0
        rawTranscript = transcription.rawTranscript
        cleanTranscript = transcription.cleanTranscript
        transcript = preferredTranscriptText(transcription)
        wordTimestamps = transcription.wordTimestamps
        speakerCount = transcription.speakerCount
        speakers = transcription.speakers
        diarizationSegments = transcription.diarizationSegments
        transcriptSegments = transcription.transcriptSegments
        calendarEventSnapshot = transcription.calendarEventSnapshot
        let artifactPaths = MeetingMarkdownArtifactPaths.resolve(
            transcription: transcription,
            promptResults: []
        )
        artifactFolderPath = artifactPaths.artifactFolderPath
        artifactManifestPath = artifactPaths.manifestPath
        artifactMarkdownPath = artifactPaths.markdownPath
        rawMicrophoneAudioPath = artifactPaths.rawMicrophoneAudioPath
        cleanedMicrophoneAudioPath = artifactPaths.cleanedMicrophoneAudioPath
        rawSystemAudioPath = artifactPaths.rawSystemAudioPath
        playbackAudioPath = artifactPaths.playbackAudioPath
        hasArtifactManifest =
            artifactPaths.manifestPath.map {
            FileManager.default.fileExists(atPath: $0)
        } ?? false
        startContext = transcription.meetingStartContext
        meetingType = classification.meetingType
        meetingLabels = classification.labels
        speakerCorrectionsApplied = projection.correctionsApplied
        textCorrectionsApplied = projection.attribution.hasTextCorrections
        speakerCorrectionRevision = projection.correctionRevision
        transcriptTextAlignment = transcription.transcriptTextAlignment
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
    let transcriptSegments: [TranscriptSegmentRecord]?
    let meetingType: MeetingType?
    let meetingLabels: [MeetingLabel]
    let speakerCorrectionsApplied: Bool
    let textCorrectionsApplied: Bool
    let speakerCorrectionRevision: Int
    let transcriptTextAlignment: TranscriptTextAlignment

    init(
        _ projection: SpeakerAttributionProjection,
        classification: MeetingClassification = MeetingClassification(meetingType: nil, labels: [])
    ) {
        let transcription = projection.effectiveTranscription
        id = transcription.id
        title = transcription.fileName
        rawTranscript = transcription.rawTranscript
        cleanTranscript = transcription.cleanTranscript
        transcript = preferredTranscriptText(transcription)
        wordTimestamps = transcription.wordTimestamps
        speakers = transcription.speakers
        transcriptSegments = transcription.transcriptSegments
        meetingType = classification.meetingType
        meetingLabels = classification.labels
        speakerCorrectionsApplied = projection.correctionsApplied
        textCorrectionsApplied = projection.attribution.hasTextCorrections
        speakerCorrectionRevision = projection.correctionRevision
        transcriptTextAlignment = transcription.transcriptTextAlignment
    }
}

private struct MeetingNotesRecord: Encodable {
    let id: UUID
    let title: String
    let notes: String?
    let hasNotes: Bool
    let updatedAt: Date
    let artifact: MeetingArtifactSnapshot?

    init(_ transcription: Transcription, artifact: MeetingArtifactSnapshot? = nil) {
        id = transcription.id
        title = transcription.fileName
        notes = transcription.userNotes
        hasNotes = normalizedNotes(transcription.userNotes) != nil
        updatedAt = transcription.updatedAt
        self.artifact = artifact
    }
}

private struct MeetingPromptResultRecord: Encodable {
    let id: UUID
    let shortID: String
    let meetingId: UUID
    let meetingTitle: String
    let promptId: UUID?
    let promptVersionId: UUID?
    let name: String
    let promptContent: String
    let extraInstructions: String?
    let content: String
    let userNotesSnapshot: String?
    let includeMeetingNotesSnapshot: Bool
    let inferenceSettingsSnapshot: PromptInferenceSettings?
    let providerSnapshot: String?
    let modelSnapshot: String?
    let createdAt: Date
    let updatedAt: Date
    let artifact: MeetingArtifactSnapshot?

    init(
        result: PromptResult,
        transcription: Transcription,
        artifact: MeetingArtifactSnapshot? = nil
    ) {
        id = result.id
        shortID = String(result.id.uuidString.prefix(8))
        meetingId = transcription.id
        meetingTitle = transcription.fileName
        promptId = result.promptId
        promptVersionId = result.promptVersionId
        name = result.promptName
        promptContent = result.promptContent
        extraInstructions = result.extraInstructions
        content = result.content
        userNotesSnapshot = result.userNotesSnapshot
        includeMeetingNotesSnapshot = result.includeMeetingNotesSnapshot
        inferenceSettingsSnapshot = result.inferenceSettingsSnapshot
        providerSnapshot = result.providerSnapshot
        modelSnapshot = result.modelSnapshot
        createdAt = result.createdAt
        updatedAt = result.updatedAt
        self.artifact = artifact
    }
}

private struct MeetingResultRepositories {
    let database: DatabaseManager
    let transcriptions: TranscriptionRepository
    let promptResults: PromptResultRepositoryProtocol
    let speakerAttributionReader: SpeakerAttributionReadService
}

private enum MeetingCorrectionHistoryAction {
    case undo
    case redo
}

enum MeetingCorrectionCLIError: LocalizedError {
    case invalidSegment(String)
    case segmentNotTargetable(String)

    var errorDescription: String? {
        switch self {
        case .invalidSegment(let value):
            "No current editable transcript line matches segment '\(value)'. Read the latest transcript JSON and retry."
        case .segmentNotTargetable(let value):
            "Transcript line '\(value)' cannot be targeted at line granularity because it does not map to one editable range."
        }
    }
}

private func correctionTarget(
    segment value: String,
    in projection: SpeakerAttributionProjection
) throws -> SpeakerCorrectionTarget {
    guard let id = UUID(uuidString: value) else {
        throw MeetingCorrectionCLIError.invalidSegment(value)
    }
    guard
        let segment = projection.effectiveTranscription.transcriptSegments?.first(where: {
            $0.id == id
        })
    else {
        throw MeetingCorrectionCLIError.invalidSegment(value)
    }
    guard
        let editable = projection.attribution.editableSegments.first(where: {
            $0.wordRange == segment.wordRange
        })
    else {
        throw MeetingCorrectionCLIError.segmentNotTargetable(value)
    }
    return SpeakerCorrectionTarget(
        anchorTranscriptSegmentIDs: editable.anchorTranscriptSegmentIDs,
        wordRange: editable.wordRange
    )
}

private func runMeetingCorrection(
    meeting: String,
    expectedRevision: Int,
    database: String?,
    json: Bool,
    envelope: Bool,
    commandName: String,
    command: (SpeakerAttributionProjection) throws -> SpeakerCorrectionCommand?
) async throws {
    let repositories = try makeMeetingResultRepositories(database: database)
    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
    let projection = try repositories.speakerAttributionReader.resolve(transcription: transcription)
    guard projection.correctionRevision == expectedRevision else {
        throw SpeakerCorrectionServiceError.conflict
    }
    if let correction = try command(projection) {
        _ = try await SpeakerCorrectionService(dbQueue: repositories.database.dbQueue).apply(
            transcriptionId: transcription.id,
            command: correction,
            expectedFingerprint: projection.attribution.fingerprint,
            expectedRevision: expectedRevision
        )
    }
    try await emitMeetingCorrectionResult(
        transcription: transcription,
        repositories: repositories,
        json: json,
        envelope: envelope,
        commandName: commandName
    )
}

private func runMeetingCorrectionHistory(
    _ action: MeetingCorrectionHistoryAction,
    meeting: String,
    expectedRevision: Int,
    database: String?,
    json: Bool,
    envelope: Bool
) async throws {
    let repositories = try makeMeetingResultRepositories(database: database)
    let transcription = try findMeeting(idOrName: meeting, repo: repositories.transcriptions)
    let projection = try repositories.speakerAttributionReader.resolve(transcription: transcription)
    guard projection.correctionRevision == expectedRevision else {
        throw SpeakerCorrectionServiceError.conflict
    }
    let service = SpeakerCorrectionService(dbQueue: repositories.database.dbQueue)
    let commandName: String
    switch action {
    case .undo:
        _ = try await service.undo(
            transcriptionId: transcription.id,
            expectedFingerprint: projection.attribution.fingerprint,
            expectedRevision: expectedRevision
        )
        commandName = "meetings corrections undo"
    case .redo:
        _ = try await service.redo(
            transcriptionId: transcription.id,
            expectedFingerprint: projection.attribution.fingerprint,
            expectedRevision: expectedRevision
        )
        commandName = "meetings corrections redo"
    }
    try await emitMeetingCorrectionResult(
        transcription: transcription,
        repositories: repositories,
        json: json,
        envelope: envelope,
        commandName: commandName
    )
}

private func emitMeetingCorrectionResult(
    transcription: Transcription,
    repositories: MeetingResultRepositories,
    json: Bool,
    envelope: Bool,
    commandName: String
) async throws {
    _ = await refreshMeetingArtifactBestEffort(
        transcription: transcription,
        repositories: repositories
    )
    let projection = try repositories.speakerAttributionReader.resolve(transcription: transcription)
    let classification = try MeetingClassificationService(dbQueue: repositories.database.dbQueue)
        .classification(for: transcription.id)
    let record = MeetingTranscriptRecord(projection, classification: classification)
    if envelope {
        try printEnvelope(command: commandName, data: record)
    } else if json {
        try printJSON(record)
    } else {
        print("Updated transcript for \(record.title) (revision \(record.speakerCorrectionRevision)).")
    }
}

private func makeMeetingResultRepositories(database: String?) throws -> MeetingResultRepositories {
    let dbManager = try makeDatabaseManager(database: database)
    return MeetingResultRepositories(
        database: dbManager,
        transcriptions: TranscriptionRepository(dbQueue: dbManager.dbQueue),
        promptResults: PromptResultRepository(dbQueue: dbManager.dbQueue),
        speakerAttributionReader: SpeakerAttributionReadService(dbQueue: dbManager.dbQueue)
    )
}

private func makeTranscriptionRepository(database: String?) throws -> TranscriptionRepository {
    let dbManager = try makeDatabaseManager(database: database)
    return TranscriptionRepository(dbQueue: dbManager.dbQueue)
}

private func materializeMeetingArtifact(
    transcription: Transcription,
    promptResults: [PromptResult],
    classification: MeetingClassification,
    speakerAttributionReader: SpeakerAttributionReading
) async throws -> MeetingArtifactSnapshot {
    try await MeetingArtifactStore(speakerAttributionReader: speakerAttributionReader).materialize(
        transcription: transcription,
        promptResults: promptResults,
        classification: MeetingArtifactClassificationSnapshot(classification)
    )
}

private func refreshMeetingArtifactBestEffort(
    transcription: Transcription,
    repositories: MeetingResultRepositories
) async -> MeetingArtifactSnapshot? {
    do {
        let promptResults = try repositories.promptResults.fetchAll(transcriptionId: transcription.id)
        let classification = try MeetingClassificationService(dbQueue: repositories.database.dbQueue)
            .classification(for: transcription.id)
        return try await materializeMeetingArtifact(
            transcription: transcription,
            promptResults: promptResults,
            classification: classification,
            speakerAttributionReader: repositories.speakerAttributionReader
        )
    } catch {
        printErr("Warning: meeting artifact refresh failed: \(error.localizedDescription)")
        return nil
    }
}

private func refreshMeetingArtifactBestEffort(
    transcription: Transcription,
    promptResults: [PromptResult],
    repositories: MeetingResultRepositories
) async -> MeetingArtifactSnapshot? {
    do {
        let classification = try MeetingClassificationService(dbQueue: repositories.database.dbQueue)
            .classification(for: transcription.id)
        return try await materializeMeetingArtifact(
            transcription: transcription,
            promptResults: promptResults,
            classification: classification,
            speakerAttributionReader: repositories.speakerAttributionReader
        )
    } catch {
        printErr("Warning: meeting artifact refresh failed: \(error.localizedDescription)")
        return nil
    }
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
    let compact =
        value
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

private func correctionTextInput(text: String?, stdin: Bool) throws -> String {
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
    guard let normalized = normalizedNonEmptyText(value) else {
        throw CLIInputError.empty
    }
    return normalized
}

private func appendedNotes(existing: String?, addition: String) -> String {
    guard let existing = normalizedNotes(existing) else { return addition }
    return existing + "\n" + addition
}

private func emitNotesUpdate(
    _ record: MeetingNotesRecord,
    json: Bool,
    envelope: Bool = false,
    command: String = "meetings notes"
) throws {
    if envelope {
        try printEnvelope(command: command, data: record)
    } else if json {
        try printJSON(record)
    } else if record.hasNotes {
        print("Updated notes for \(record.title).")
    } else {
        print("Cleared notes for \(record.title).")
    }
}

private func exportContent(
    for projection: SpeakerAttributionProjection,
    format: MeetingExportFormat,
    promptResults: [PromptResult],
    classification: MeetingClassification
) throws -> String {
    let transcription = projection.effectiveTranscription
    switch format {
    case .md:
        let artifactPaths = MeetingMarkdownArtifactPaths.resolve(
            transcription: transcription,
            promptResults: promptResults
        )
        return MeetingMarkdownRenderer().render(
            transcription: transcription,
            promptResults: promptResults,
            artifactPaths: artifactPaths,
            speakerCorrectionsApplied: projection.correctionsApplied,
            speakerCorrectionRevision: projection.correctionRevision,
            classification: MeetingArtifactClassificationSnapshot(classification)
        )
    case .json:
        let data = try cliJSONEncoder.encode(
            MeetingRecord(
                projection,
                promptResultCount: promptResults.count,
                classification: classification
            )
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }
}

private func printMeetingRecord(_ record: MeetingRecord) {
    print(record.title)
    print("ID: \(record.id.uuidString)")
    print("Created: \(formatDate(record.createdAt))")
    print("Duration: \(record.durationMs.map(formatDuration) ?? "--")")
    print("Status: \(record.status.rawValue)")
    print("Prompt results: \(record.promptResultCount)")
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
    let baseName = sanitizedFileName(
        URL(fileURLWithPath: transcription.fileName).deletingPathExtension().lastPathComponent)
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("\(baseName).\(fileExtension)")
}

private func sanitizedFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:")
    let cleaned =
        value
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

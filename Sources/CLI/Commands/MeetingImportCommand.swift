import ArgumentParser
import Foundation
import MacParakeetCore

typealias MeetingImportRunning =
    @Sendable (
        MeetingImportRequest,
        @escaping @Sendable (MeetingImportProgress) -> Void
    ) async throws -> MeetingImportResult

/// Test-only injection stays outside the ArgumentParser command so command
/// decoding remains synthesized. Production leaves this empty and constructs
/// the real Core service below.
final class MeetingImportRunnerOverride: @unchecked Sendable {
    private let lock = NSLock()
    private var runner: MeetingImportRunning?

    func set(_ runner: MeetingImportRunning?) {
        lock.lock()
        self.runner = runner
        lock.unlock()
    }

    func current() -> MeetingImportRunning? {
        lock.lock()
        defer { lock.unlock() }
        return runner
    }
}

let meetingImportRunnerOverride = MeetingImportRunnerOverride()

extension MeetingsCommand {
    struct ImportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Import one existing audio or video recording as a managed meeting.",
            discussion: """
                MacParakeet creates its own managed audio copy and never changes the source file. \
                The imported meeting receives normal transcription, speaker processing, search, \
                playback, and enabled meeting notes. A transcript-saved partial result exits zero; \
                a retryable transcription result prints its saved meeting first, then exits one. \
                If interrupted after that meeting is saved, it prints the result and exits 130. \
                Re-running import always creates another meeting, so open a retryable meeting and \
                choose Retry Transcription instead.
                """
        )

        @Argument(help: "Path to one local audio or video recording.")
        var path: String

        @Option(name: .long, help: "Explicit meeting title. Defaults to the filename without its extension.")
        var title: String?

        @Option(name: .long, help: "Historical meeting date: YYYY-MM-DD (local midnight) or an ISO-8601 timestamp.")
        var startedAt: String?

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json = false

        @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
        var envelope = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--title must contain non-whitespace text.")
            }
            _ = try Self.parseStartedAt(startedAt)
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json || envelope) {
                let request = MeetingImportRequest(
                    sourceURL: URL(fileURLWithPath: expandTilde(path)),
                    titleOverride: title,
                    startedAt: try Self.parseStartedAt(startedAt)
                )
                let result: MeetingImportResult
                var wasInterrupted = false
                do {
                    let processing = try await withSIGINTCooperativeCancellationResult {
                        try await withStandardOutputRedirectedToStandardError {
                            if let importRunner = meetingImportRunnerOverride.current() {
                                return try await importRunner(request, meetingImportProgressToStderr)
                            }
                            let dbManager = try makeDatabaseManager(database: database)
                            let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
                            let service = try makeMeetingImportService(
                                dbManager: dbManager, transcriptionRepo: repo)
                            return try await service.importMeeting(request, onProgress: meetingImportProgressToStderr)
                        }
                    }
                    result = processing.value
                    wasInterrupted = processing.wasInterrupted
                } catch is CancellationError {
                    throw ExitCode(130)
                }

                let record = MeetingImportRecord(result)
                if envelope {
                    try printEnvelope(
                        command: "meetings import", data: record, warnings: record.warnings.map(\.message))
                } else if json {
                    try printJSON(record)
                } else {
                    printMeetingImport(record)
                }
                if wasInterrupted {
                    throw ExitCode(130)
                }
                if result.completion == .needsRetry {
                    throw ExitCode.failure
                }
            }
        }

        static func parseStartedAt(_ value: String?) throws -> Date? {
            guard let value else { return nil }
            if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar.current
                formatter.timeZone = .current
                formatter.dateFormat = "yyyy-MM-dd"
                guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
                    throw ValidationError("--started-at must be YYYY-MM-DD or an ISO-8601 timestamp.")
                }
                return date
            }
            guard value.contains("T") else {
                throw ValidationError("--started-at must be YYYY-MM-DD or an ISO-8601 timestamp.")
            }
            let formatters: [ISO8601DateFormatter] = [
                ISO8601DateFormatter(),
                {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return formatter
                }(),
            ]
            guard let date = formatters.compactMap({ $0.date(from: value) }).first else {
                throw ValidationError("--started-at must be YYYY-MM-DD or an ISO-8601 timestamp.")
            }
            return date
        }
    }
}

private func makeMeetingImportService(
    dbManager: DatabaseManager,
    transcriptionRepo: TranscriptionRepository
) throws -> MeetingImportService {
    let processing = try SavedMeetingProcessingContext(
        dbManager: dbManager, transcriptionRepo: transcriptionRepo)
    return MeetingImportService(
        transcriptionService: processing.transcriptionService,
        transcriptionRepo: transcriptionRepo,
        completionService: processing.completionService,
        recordingsRoot: { processing.recordingsRootURL },
        lockFileStore: processing.lockFileStore
    )
}

private let meetingImportProgressToStderr: @Sendable (MeetingImportProgress) -> Void = { progress in
    switch progress {
    case .preparingMedia:
        printErr("Preparing audio")
    case .published(let transcription):
        printErr("Meeting saved: \(transcription.id.uuidString)")
    case .transcription(let stage):
        switch stage {
        case .converting: printErr("Transcribing recording: preparing audio")
        case .downloading: printErr("Transcribing recording: preparing speech model")
        case .preparingSpeechModel: printErr("Transcribing recording: preparing speech model")
        case .transcribing: printErr("Transcribing recording")
        case .identifyingSpeakers: printErr("Finishing meeting: identifying speakers")
        case .finalizing: printErr("Finishing meeting")
        }
    case .automation:
        printErr("Running meeting notes")
    }
}

struct MeetingImportRecord: Encodable {
    let id: UUID
    let completion: String
    let status: String
    let title: String
    let startedAt: Date
    let durationMs: Int?
    let managedAudioPath: String?
    let warnings: [MeetingImportWarningRecord]

    init(_ result: MeetingImportResult) {
        let transcription = result.transcription
        id = transcription.id
        completion = result.completion.rawValue
        status = transcription.status.rawValue
        title = transcription.effectiveDisplayTitle
        startedAt = transcription.createdAt
        durationMs = transcription.durationMs
        managedAudioPath =
            MeetingArtifactStore.sessionFolderURL(for: transcription)?
            .appendingPathComponent(MeetingArtifactAudioFileNames.playback).path
        warnings = result.warnings.map(MeetingImportWarningRecord.init)
    }
}

struct MeetingImportWarningRecord: Encodable {
    let kind: String
    let message: String
    let promptId: UUID?
    let promptName: String?

    init(_ warning: MeetingImportWarning) {
        switch warning {
        case .transcriptionFailed:
            kind = "transcriptionFailed"
            message = "Transcription needs another try. The saved meeting is available in Meetings."
            promptId = nil
            promptName = nil
        case .transcriptionCancelled:
            kind = "transcriptionCancelled"
            message = "Transcription was stopped. The saved meeting can be retried."
            promptId = nil
            promptName = nil
        case .persistenceFailed:
            kind = "persistenceFailed"
            message = "Some saved-meeting details need attention. The transcript is ready."
            promptId = nil
            promptName = nil
        case .settlementFailed:
            kind = "settlementFailed"
            message = "Some saved-meeting details need attention. The transcript is ready."
            promptId = nil
            promptName = nil
        case .ownershipReleaseFailed:
            kind = "ownershipReleaseFailed"
            message = "Some saved-meeting details need attention. The transcript is ready."
            promptId = nil
            promptName = nil
        case .automationFailed:
            kind = "automationFailed"
            message = "Some meeting notes could not finish. The transcript is ready."
            promptId = nil
            promptName = nil
        case .automationCancelled:
            kind = "automationCancelled"
            message = "Meeting notes stopped before they finished. The transcript is ready."
            promptId = nil
            promptName = nil
        case .promptFailed(let id, let name, _):
            kind = "promptFailed"
            message = "An enabled meeting note could not finish. The transcript is ready."
            promptId = id
            promptName = name
        case .knowledgeCardFailed:
            kind = "knowledgeCardFailed"
            message = "The knowledge card could not finish. The transcript is ready."
            promptId = nil
            promptName = nil
        case .artifactRefreshFailed:
            kind = "artifactRefreshFailed"
            message = "Some meeting details could not finish. The transcript is ready."
            promptId = nil
            promptName = nil
        }
    }
}

private func printMeetingImport(_ record: MeetingImportRecord) {
    print("Meeting \"\(record.title)\" [\(record.status)]")
    print("  ID: \(record.id.uuidString)")
    print("  Started: \(ISO8601DateFormatter().string(from: record.startedAt))")
    if let durationMs = record.durationMs { print("  Duration: \(durationMs)ms") }
    if let managedAudioPath = record.managedAudioPath { print("  Managed audio: \(managedAudioPath)") }
    for warning in record.warnings { print("  Warning: \(warning.message)") }
    switch record.completion {
    case MeetingImportResult.Completion.completed.rawValue,
        MeetingImportResult.Completion.partial.rawValue:
        print("  Transcript, search, and playback are ready. Your source recording was unchanged.")
    default:
        print(
            "  Meeting and managed audio are saved. Open it and choose Retry Transcription; do not import the file again."
        )
    }
}

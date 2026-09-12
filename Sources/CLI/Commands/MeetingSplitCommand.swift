import ArgumentParser
import CryptoKit
import Darwin
import Dispatch
import Foundation
import MacParakeetCore

/// CLI surface for Split and transcribe (plan #895 U2). One shared Core
/// operation (`MeetingSplitService`) serves both this CLI and any future
/// native UI; this file only adapts CLI flags/output to that Core API.
///
/// Uses the app's saved transcription model and enabled completion settings.
extension MeetingsCommand {
    struct SplitSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "split",
            abstract: "Split a saved meeting recording into independent parts, each receiving its own first transcription.",
            discussion: """
                Every part, including the first, is a brand-new saved meeting that receives its own \
                first transcription and normal enabled completion automation (e.g. summaries). The \
                original recording, its transcript, and its derived content are never modified, \
                retranscribed, or deleted.
                """,
            subcommands: [
                PreviewSubcommand.self,
                CreateSubcommand.self,
                StatusSubcommand.self,
                ResumeSubcommand.self,
                DiscardSubcommand.self,
            ]
        )
    }
}

// MARK: - preview

extension MeetingsCommand.SplitSubcommand {
    struct PreviewSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "preview",
            abstract: "Read-only preview of the parts a split would produce. Performs no writes."
        )

        @Argument(help: "The UUID, UUID prefix, or exact title of the meeting to split.")
        var meeting: String

        @Option(name: .long, help: "A cut point in milliseconds from the start of the recording; repeatable, ascending.")
        var cut: [Int] = []

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
                let dbManager = try makeReadOnlySplitDatabaseManager(database: database)
                let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
                let sourceId = try resolvedMeetingSourceId(meeting, repo: transcriptionRepo)
                let preview = try await readOnlySplitPreview(sourceId: sourceId, cuts: cut, repo: transcriptionRepo)

                if envelope {
                    try printEnvelope(command: "meetings split preview", data: preview)
                    return
                }
                if json {
                    try printJSON(preview)
                    return
                }
                printSplitPreview(preview)
            }
        }
    }
}

// MARK: - create (and process)

extension MeetingsCommand.SplitSubcommand {
    struct CreateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Split a saved meeting and process every part sequentially: first transcription, then enabled automation.",
            discussion: """
                Safe to run again with identical arguments after an interruption at any point: the \
                same audio parts and processing progress are reused, never duplicated. Use \
                `meetings split resume` after changing nothing but retrying a prior failure. A \
                committed retry works even after the original recording has been deleted, as long as \
                --key (or the same default arguments) identify the same operation. A discarded \
                operation's --key is a permanent tombstone: retry with a fresh --key, not the \
                original one. Interrupted by Ctrl-C (SIGINT): finishes settling in-flight work \
                before exiting 130; already-published parts and their completed stages are kept.
                """
        )

        @Argument(help: "The UUID, UUID prefix, or exact title of the meeting to split. An exact UUID is accepted even if the recording no longer exists, for retrying a committed split.")
        var meeting: String

        @Option(name: .long, help: "A cut point in milliseconds from the start of the recording; repeatable, ascending.")
        var cut: [Int] = []

        @Option(name: .long, help: "Title for one resulting part, in order; must supply exactly cuts.count + 1.")
        var title: [String] = []

        @Option(
            name: .long,
            help: "Explicit idempotency key. Defaults to a stable key derived from the meeting id, cuts and titles, so repeating the same invocation never creates duplicate parts."
        )
        var key: String?

        @Option(
            name: .long,
            help: "The opaque sourceIdentity string printed by `preview`. When supplied, creation (or a same-key retry) fails if the recording's audio has changed since that identity was captured."
        )
        var expectedIdentity: String?

        @Flag(name: .long, help: "Validate and print the preview only; performs no writes, migrations or lock files.")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
        var envelope: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            guard !dryRun || title.isEmpty || title.count == cut.count + 1 else {
                throw ValidationError("--title must be supplied exactly cuts.count + 1 times (or omitted for --dry-run).")
            }
            guard dryRun || title.count == cut.count + 1 else {
                throw ValidationError("--title must be supplied exactly cuts.count + 1 times.")
            }
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json || envelope) {
                if dryRun {
                    // Preview never writes, migrates or creates a lock file:
                    // the readonly database entry point is used for the
                    // *entire* dry-run branch, not just the preview call.
                    let dbManager = try makeReadOnlySplitDatabaseManager(database: database)
                    let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
                    let sourceId = try resolvedMeetingSourceId(meeting, repo: transcriptionRepo)
                    let preview = try await readOnlySplitPreview(sourceId: sourceId, cuts: cut, repo: transcriptionRepo)
                    if envelope {
                        try printEnvelope(command: "meetings split create", data: preview)
                        return
                    }
                    if json {
                        try printJSON(preview)
                        return
                    }
                    print("(dry run; nothing was created)")
                    printSplitPreview(preview)
                    return
                }

                let dbManager = try makeMutatingSplitDatabaseManager(database: database)
                let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
                let sourceId = try resolvedMeetingSourceId(meeting, repo: transcriptionRepo)
                let service = makeMeetingSplitService(dbManager: dbManager, transcriptionRepo: transcriptionRepo)

                let idempotencyKey = key ?? Self.defaultIdempotencyKey(sourceId: sourceId, cuts: cut, titles: title)
                let operation: MeetingSplitOperation
                do {
                    operation = try await withSIGINTCooperativeCancellation {
                        try await withStandardOutputRedirectedToStandardError {
                            try await service.createAndProcess(
                                idempotencyKey: idempotencyKey,
                                sourceId: sourceId,
                                cutPointsMs: cut,
                                titles: title,
                                expectedSourceIdentity: expectedIdentity,
                                onProgress: splitProgressToStderr
                            )
                        }
                    }
                } catch is CancellationError {
                    throw ExitCode(130)
                } catch MeetingSplitRepositoryError.operationNotCommitted(.discarded) {
                    throw MeetingSplitRetryGuidanceError.discardedKeyIsATombstone(idempotencyKey: idempotencyKey)
                }

                if envelope {
                    try printEnvelope(command: "meetings split create", data: operation)
                } else if json {
                    try printJSON(operation)
                } else {
                    printSplitOperation(operation)
                }
                try throwIfAnyChildFailed(operation)
            }
        }

        /// A pure function of the structured payload (never a delimiter join
        /// of user-supplied strings, which can collide across different
        /// cut/title splits that happen to concatenate to the same text).
        static func defaultIdempotencyKey(sourceId: UUID, cuts: [Int], titles: [String]) -> String {
            struct Payload: Encodable {
                let sourceId: UUID
                let cuts: [Int]
                let titles: [String]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(Payload(sourceId: sourceId, cuts: cuts, titles: titles)) else {
                return "cli-split:\(sourceId.uuidString)"
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return "cli-split:\(digest)"
        }
    }
}

// MARK: - status

extension MeetingsCommand.SplitSubcommand {
    struct StatusSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show one split operation's progress, or discover prior operations for a source recording."
        )

        @Argument(help: "The split operation UUID. Omit when using --source.")
        var operationId: String?

        @Option(
            name: .long,
            help: "List every split operation recorded for this meeting instead of looking up a single operation id. An exact UUID is accepted even if the recording no longer exists."
        )
        var source: String?

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
        var envelope: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            guard (operationId == nil) != (source == nil) else {
                throw ValidationError("Pass exactly one of an operation id or --source.")
            }
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json || envelope) {
                let dbManager = try makeReadOnlySplitDatabaseManager(database: database)
                let splitRepo = MeetingSplitRepository(dbQueue: dbManager.dbQueue)

                if let source {
                    // Discovery by exact historical source UUID must work
                    // after the source itself has been deleted: never routed
                    // through `findMeeting`, which requires the row to exist.
                    let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
                    let sourceId = try resolvedMeetingSourceId(source, repo: transcriptionRepo)
                    let operations = try splitRepo.operations(sourceId: sourceId)
                    if envelope {
                        try printEnvelope(command: "meetings split status", data: operations)
                        return
                    }
                    if json {
                        try printJSON(operations)
                        return
                    }
                    guard !operations.isEmpty else {
                        print("No split operations recorded for this meeting.")
                        return
                    }
                    for operation in operations {
                        printSplitOperation(operation)
                    }
                    return
                }

                guard let operationIdString = operationId, let uuid = UUID(uuidString: operationIdString) else {
                    throw ValidationError("operation id must be a UUID.")
                }
                guard let operation = try splitRepo.operation(id: uuid) else {
                    throw CLILookupError.notFound("No split operation matches '\(operationIdString)'")
                }
                if envelope {
                    try printEnvelope(command: "meetings split status", data: operation)
                    return
                }
                if json {
                    try printJSON(operation)
                    return
                }
                printSplitOperation(operation)
            }
        }
    }
}

// MARK: - resume

extension MeetingsCommand.SplitSubcommand {
    struct ResumeSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resume",
            abstract: "Resume processing a committed split operation without recreating audio.",
            discussion: """
                Retries only unfinished/failed children; completed transcripts and automation are \
                never repeated. Explicit cancellation of a prior run leaves unstarted parts retryable. \
                Only accepts a committed operation: if it never finished creating (still preparing), \
                rerun `meetings split create` with the original arguments instead, which is safe to \
                repeat; a discarded operation cannot be resumed at all. Interrupted by Ctrl-C (SIGINT): \
                finishes settling in-flight work before exiting 130.
                """
        )

        @Argument(help: "The split operation UUID.")
        var operationId: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
        var envelope: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            guard UUID(uuidString: operationId) != nil else {
                throw ValidationError("operation id must be a UUID.")
            }
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json || envelope) {
                let dbManager = try makeMutatingSplitDatabaseManager(database: database)
                let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
                let service = makeMeetingSplitService(dbManager: dbManager, transcriptionRepo: transcriptionRepo)
                let uuid = try parsedOperationId(operationId)

                let operation: MeetingSplitOperation
                do {
                    operation = try await withSIGINTCooperativeCancellation {
                        try await withStandardOutputRedirectedToStandardError {
                            try await service.resumeProcessing(operationId: uuid, onProgress: splitProgressToStderr)
                        }
                    }
                } catch is CancellationError {
                    throw ExitCode(130)
                } catch MeetingSplitRepositoryError.operationNotCommitted(.preparing) {
                    throw MeetingSplitRetryGuidanceError.stillPreparingRerunCreate(operationId: uuid)
                } catch MeetingSplitRepositoryError.operationNotCommitted(.discarded) {
                    throw MeetingSplitRetryGuidanceError.discardedOperationCannotResume(operationId: uuid)
                }

                if envelope {
                    try printEnvelope(command: "meetings split resume", data: operation)
                } else if json {
                    try printJSON(operation)
                } else {
                    printSplitOperation(operation)
                }
                try throwIfAnyChildFailed(operation)
            }
        }
    }
}

// MARK: - discard

extension MeetingsCommand.SplitSubcommand {
    struct DiscardSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "discard",
            abstract: "Abandon a not-yet-published split operation and remove its unpublished output.",
            discussion: """
                Refused once the operation has committed audio parts; committed splits cannot be \
                undone. A discarded operation's --key is a permanent tombstone: to retry, rerun \
                `meetings split create` with a fresh --key (the same original --key will not work).
                """
        )

        @Argument(help: "The split operation UUID.")
        var operationId: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
        var envelope: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            try validateJSONEnvelopeFlags(json: json, envelope: envelope)
            guard UUID(uuidString: operationId) != nil else {
                throw ValidationError("operation id must be a UUID.")
            }
        }

        func run() async throws {
            try emitJSONOrRethrow(json: json || envelope) {
                let dbManager = try makeMutatingSplitDatabaseManager(database: database)
                let transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
                let service = makeMeetingSplitService(dbManager: dbManager, transcriptionRepo: transcriptionRepo)
                let uuid = try parsedOperationId(operationId)

                let operation = try service.discard(operationId: uuid)

                if envelope {
                    try printEnvelope(command: "meetings split discard", data: operation)
                    return
                }
                if json {
                    try printJSON(operation)
                    return
                }
                print("Discarded split operation \(operation.id).")
            }
        }
    }
}

// MARK: - Cooperative SIGINT cancellation

/// Installs a SIGINT (Ctrl-C) handler for the duration of `operation`,
/// cancelling `operation`'s own `Task` instead of letting the default
/// terminate-on-SIGINT disposition kill the process outright. Cancellation
/// is cooperative: this only sets the task's cancellation flag and then
/// awaits it, so a split already mid-write (see
/// `MeetingSplitService.processAll`) finishes settling — marking the
/// in-flight child cancelled and leaving every other completed stage intact
/// — before this function returns. Callers translate the resulting
/// `CancellationError` into `ExitCode(130)` themselves, mirroring the
/// existing convention (see `CardsCommand`). Restores whatever SIGINT
/// disposition was active before this call once `operation` finishes, so it
/// never leaks past this one command.
func withSIGINTCooperativeCancellation<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let task = Task { try await operation() }
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    // Disable the default terminate-on-SIGINT disposition first: left in
    // place, the signal's default action can still terminate the process
    // before the dispatch source below ever gets a chance to fire.
    let previousDisposition = signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler { task.cancel() }
    signalSource.resume()
    defer {
        signalSource.cancel()
        signal(SIGINT, previousDisposition)
    }
    let value = try await task.value
    guard !task.isCancelled else { throw CancellationError() }
    return value
}

// MARK: - Retry guidance for a non-committed operation

/// `MeetingSplitRepositoryError.operationNotCommitted` fires identically
/// whether reached via a `create` retry of a discarded idempotency key or a
/// `resume` of an operation that never finished creating. This replaces that
/// generic status message with the one actionable next step, without
/// changing the underlying repository's terminal/idempotency semantics: a
/// discarded operation stays permanently discarded, and `resume` still
/// refuses anything but `.committed`.
enum MeetingSplitRetryGuidanceError: Error, Equatable, LocalizedError {
    case discardedKeyIsATombstone(idempotencyKey: String)
    case discardedOperationCannotResume(operationId: UUID)
    case stillPreparingRerunCreate(operationId: UUID)

    var errorDescription: String? {
        switch self {
        case .discardedKeyIsATombstone(let idempotencyKey):
            return """
                Idempotency key '\(idempotencyKey)' was already discarded; a discarded key is a \
                permanent tombstone. Retry with a fresh --key (the same source/cuts/titles).
                """
        case .discardedOperationCannotResume(let operationId):
            return """
                Split operation \(operationId) was discarded and cannot be resumed. Retry with \
                `meetings split create` and a fresh --key instead.
                """
        case .stillPreparingRerunCreate(let operationId):
            return """
                Split operation \(operationId) never finished creating (still preparing). `resume` \
                only retries committed operations; rerun `meetings split create` with the original \
                arguments instead — safe to repeat.
                """
        }
    }
}

// MARK: - Shared construction

private func parsedOperationId(_ value: String) throws -> UUID {
    guard let uuid = UUID(uuidString: value) else {
        throw ValidationError("operation id must be a UUID.")
    }
    return uuid
}

/// An exact UUID is accepted directly, without requiring `findMeeting` (which
/// requires the row to still exist) to succeed — a committed split's retry,
/// or `status --source`, must be resolvable purely from a historical source
/// id after the recording has been deleted. Anything else falls back to the
/// normal id-prefix/title lookup, which does require the row to exist.
private func resolvedMeetingSourceId(_ value: String, repo: TranscriptionRepository) throws -> UUID {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let uuid = UUID(uuidString: trimmed) {
        return uuid
    }
    return try findMeeting(idOrName: trimmed, repo: repo).id
}

/// Phase progress is written to stderr only, mirroring `transcribe`'s own
/// convention: stdout stays clean JSON (or the plain-text summary) for
/// piping, regardless of `--json`/`--envelope`.
private let splitProgressToStderr: @Sendable (MeetingSplitProcessingProgress) -> Void = { progress in
    printErr("Part \(progress.childIndex + 1)/\(progress.childCount): \(progress.stage.rawValue)")
}

/// A partial failure (any child that ended a stage in `.failed`) must never
/// be presented as an unqualified success: the operation is still printed in
/// full above, but the process exits non-zero so an automated caller cannot
/// mistake this for total success without inspecting every child.
private func throwIfAnyChildFailed(_ operation: MeetingSplitOperation) throws {
    guard operation.childProgress.contains(where: { $0.outcome == .failed }) else { return }
    throw ExitCode.failure
}

/// Preview never migrates, writes or creates a lock file: use the read-only
/// database entry point, matching `health`'s non-mutating probe contract.
private func makeReadOnlySplitDatabaseManager(database: String?) throws -> DatabaseManager {
    try DatabaseManager(readOnlyPath: resolvedDatabasePath(database))
}

private func readOnlySplitPreview(
    sourceId: UUID, cuts: [Int], repo: TranscriptionRepository
) async throws -> MeetingSplitPreview {
    guard let source = try repo.fetch(id: sourceId) else { throw MeetingSplitServiceError.sourceNotFound }
    return try await MeetingSplitService.preview(
        source: source, cutPointsMs: cuts,
        retention: UserDefaultsAppRuntimePreferences.meetingAudioRetention(
            defaults: AppPaths.appDefaults(), persistMigration: false
        )
    )
}

private func makeMutatingSplitDatabaseManager(database: String?) throws -> DatabaseManager {
    try makeDatabaseManager(database: database)
}

/// Uses the shared saved-audio pipeline with app preferences. Preview and
/// status never construct these processing services.
private func makeMeetingSplitService(
    dbManager: DatabaseManager,
    transcriptionRepo: TranscriptionRepository
) -> MeetingSplitService {
    let dbQueue = dbManager.dbQueue
    let defaults = AppPaths.appDefaults()
    let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)
    let llmService = LLMService()
    let splitRepo = MeetingSplitRepository(dbQueue: dbQueue)
    let promptRepo = PromptRepository(dbQueue: dbQueue)
    let promptResultRepo = PromptResultRepository(dbQueue: dbQueue)
    let promptLabelPolicyRepository = PromptLabelPolicyRepository(dbQueue: dbQueue)
    let transcriptionLabelRepository = TranscriptionMeetingLabelRepository(dbQueue: dbQueue)
    let speakerAttributionReader = SpeakerAttributionReadService(dbQueue: dbQueue)
    let customWordRepo = CustomWordRepository(dbQueue: dbQueue)
    let segmentRepo = SegmentRepository(dbQueue: dbQueue)
    let knowledgeLayerMutator = KnowledgeLayerMutationService(dbQueue: dbQueue)
    let snippetRepo = TextSnippetRepository(dbQueue: dbQueue)

    let sttClient = STTClient(
        parakeetModelVariant: SpeechEnginePreference.parakeetModelVariant(defaults: defaults),
        speechEngine: SpeechEnginePreference.finalTranscription(defaults: defaults),
        nemotronModelVariant: SpeechEnginePreference.nemotronModelVariant(defaults: defaults),
        whisperModelVariant: SpeechEnginePreference.whisperModelVariant(defaults: defaults),
        defaults: defaults,
        customWordRepository: customWordRepo
    )
    // The exact construction path saved-meeting `retranscribe`/automatic
    // completion already uses: real STT client, meeting speaker-diarization
    // preference wired through, and no CLI-invented per-invocation flags.
    let transcriptionService = TranscriptionService(
        audioProcessor: AudioProcessor(),
        sttTranscriber: sttClient,
        transcriptionRepo: transcriptionRepo,
        segmentRepo: segmentRepo,
        knowledgeLayerMutator: knowledgeLayerMutator,
        promptResultRepo: promptResultRepo,
        customWordRepo: customWordRepo,
        snippetRepo: snippetRepo,
        processingMode: { preferences.processingMode },
        llmService: llmService,
        llmRunRepo: LLMRunRepository(dbQueue: dbQueue),
        shouldUseAIFormatter: { preferences.aiFormatterEnabled && preferences.aiFormatterEnabledForTranscriptions },
        aiFormatterPromptTemplate: { preferences.aiFormatterPrompt },
        shouldAutoGenerateMeetingTitles: { preferences.shouldAutoGenerateMeetingTitles },
        shouldDiarize: { preferences.shouldDiarize },
        shouldDiarizeMeetings: { preferences.shouldDiarizeMeetings },
        fileSpeechEngineSelection: { SpeechEngineSelection.finalTranscription(defaults: defaults) },
        diarizationService: DiarizationService(),
        meetingArtifactStore: MeetingArtifactStore(speakerAttributionReader: speakerAttributionReader)
    )

    let completionService = SavedAudioAutoPromptCompletionService(
        promptRepo: promptRepo,
        promptResultRepo: promptResultRepo,
        llmService: llmService,
        promptLabelPolicyRepository: promptLabelPolicyRepository,
        transcriptionLabelRepository: transcriptionLabelRepository,
        speakerAttributionReader: speakerAttributionReader,
        meetingArtifactStore: MeetingArtifactStore(speakerAttributionReader: speakerAttributionReader)
    )

    return MeetingSplitService(
        transcriptionRepo: transcriptionRepo,
        splitRepo: splitRepo,
        transcriptionService: transcriptionService,
        completionService: completionService,
        meetingRecordingsRootURL: { splitMeetingRecordingsRootURL(defaults: defaults) },
        retentionConfig: { UserDefaultsAppRuntimePreferences.meetingAudioRetention(defaults: defaults, persistMigration: false) },
        speechEngineSelection: { SpeechEngineSelection.finalTranscription(defaults: defaults) }
    )
}

/// The meeting-recordings root this CLI process should create/resume/discard
/// splits under: the same `meetingArtifactsFolder`/DEBUG-state-dir resolution
/// `AppPaths.meetingRecordingsDir` uses, but scoped to `defaults` (the CLI's
/// own resolved preferences domain from `AppPaths.appDefaults()`, not always
/// `.standard`) so a non-default folder preference set in that domain is
/// honored here too. Without this, `MeetingSplitService`'s own default falls
/// back to `.standard`, which is the wrong domain for a standalone CLI
/// process reading the app's shared suite.
func splitMeetingRecordingsRootURL(defaults: UserDefaults) -> URL {
    URL(fileURLWithPath: AppPaths.configuredMeetingRecordingsDir(defaults: defaults), isDirectory: true)
}

// MARK: - Human-readable printing

private func printSplitPreview(_ preview: MeetingSplitPreview) {
    print("Split preview for \"\(preview.sourceTitle)\" (\(preview.sourceId))")
    print("  Total duration: \(preview.totalDurationMs)ms")
    print(
        "  Tracks: playback"
            + (preview.hasRawMicrophone ? " + microphone" : "")
            + (preview.hasRawSystem ? " + system" : "")
            + (preview.hasCleanedMicrophone ? " + cleaned-microphone" : "")
    )
    if !preview.hasRawMicrophone && !preview.hasRawSystem && !preview.hasCleanedMicrophone {
        print("  (canonical playback only: no raw/cleaned track has both its file and usable alignment metadata)")
    }
    for (index, range) in preview.ranges.enumerated() {
        print("  Part \(index + 1): [\(range.startMs)ms, \(range.endMs)ms) — \(range.durationMs)ms")
    }
    print("  Each part is a new saved meeting receiving its own first transcription and enabled automation.")
    print("  The original recording is never modified, retranscribed or deleted.")
}

private func printSplitOperation(_ operation: MeetingSplitOperation) {
    print("Split operation \(operation.id) [\(operation.status.rawValue)] for source \(operation.sourceId)")
    for progress in operation.childProgress {
        let outcome = progress.outcome == .none ? "" : " (\(progress.outcome.rawValue))"
        print("  Child \(progress.childId): \(progress.stage.rawValue)\(outcome)")
        if let errorMessage = progress.errorMessage {
            print("    \(errorMessage)")
        }
    }
}

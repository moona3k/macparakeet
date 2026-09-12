import CryptoKit
import Foundation

// MARK: - Source identity (explicit expected identity at the Core boundary)

/// A caller-observable identity of a split source at a moment in time,
/// captured once by `preview` and optionally re-supplied to
/// `createAndProcess` as `expectedSourceIdentity`. Deliberately richer than
/// duration+size+rounded creation time alone: distinct per-track size/
/// modification-time identities let a same-duration/same-size replacement (a
/// re-recorded or re-encoded file swapped in at the same path) be detected
/// without decoding or hashing audio content, and without ever touching the
/// source's transcript text.
private struct MeetingSplitSourceIdentity: Sendable, Equatable, Codable {
    public let sourceId: UUID
    public let sourceCreatedAt: Date
    public let sourceStatus: Transcription.TranscriptionStatus
    public let sourcePath: String?
    public let durationMs: Int
    public let canonical: MeetingSplitSourceMediaInspection.FileIdentity
    public let rawMicrophone: MeetingSplitSourceMediaInspection.FileIdentity?
    public let rawSystem: MeetingSplitSourceMediaInspection.FileIdentity?
    public let cleanedMicrophone: MeetingSplitSourceMediaInspection.FileIdentity?

    public init(source: Transcription, inspection: MeetingSplitSourceMediaInspection) {
        self.sourceId = source.id
        self.sourceCreatedAt = source.createdAt
        self.sourceStatus = source.status
        self.sourcePath = source.filePath
        self.durationMs = inspection.durationMs
        self.canonical = inspection.canonicalIdentity
        self.rawMicrophone = inspection.rawMicrophoneIdentity
        self.rawSystem = inspection.rawSystemIdentity
        self.cleanedMicrophone = inspection.cleanedMicrophoneIdentity
    }
}

// MARK: - Preview (read-only)

/// A read-only description of what splitting `sourceId` at `cutPointsMs`
/// would produce. Performs no writes, migrations or lock creation — see
/// `MeetingSplitAudioExporter.inspectSource`.
public struct MeetingSplitPreview: Sendable, Equatable, Codable {
    public let sourceId: UUID
    public let sourceTitle: String
    public let totalDurationMs: Int
    public let ranges: [MeetingSplitSourceRange]
    /// Source track availability requires both the file and its alignment.
    /// Individual parts receive only the overlapping audio. Missing optional
    /// tracks never block canonical playback splitting.
    public let hasRawMicrophone: Bool
    public let hasRawSystem: Bool
    /// Uses microphone alignment, but does not require the raw file to remain.
    public let hasCleanedMicrophone: Bool
    /// Caller-observed media/source identity captured at preview time. Pass
    /// this back into `createAndProcess(expectedSourceIdentity:)` to require
    /// the source be unchanged at creation time; omit it to skip that check.
    public let sourceIdentity: String

    public init(
        sourceId: UUID,
        sourceTitle: String,
        totalDurationMs: Int,
        ranges: [MeetingSplitSourceRange],
        hasRawMicrophone: Bool,
        hasRawSystem: Bool,
        hasCleanedMicrophone: Bool,
        sourceIdentity: String
    ) {
        self.sourceId = sourceId
        self.sourceTitle = sourceTitle
        self.totalDurationMs = totalDurationMs
        self.ranges = ranges
        self.hasRawMicrophone = hasRawMicrophone
        self.hasRawSystem = hasRawSystem
        self.hasCleanedMicrophone = hasCleanedMicrophone
        self.sourceIdentity = sourceIdentity
    }
}

// MARK: - Processing progress

public struct MeetingSplitProcessingProgress: Sendable, Equatable {
    public let operationId: UUID
    public let childId: UUID
    public let childIndex: Int
    public let childCount: Int
    public let stage: MeetingSplitChildStage

    public init(operationId: UUID, childId: UUID, childIndex: Int, childCount: Int, stage: MeetingSplitChildStage) {
        self.operationId = operationId
        self.childId = childId
        self.childIndex = childIndex
        self.childCount = childCount
        self.stage = stage
    }
}

// MARK: - Ownership

/// Whether a split operation is currently being actively worked by some
/// process, derived from `MeetingSplitOperationLease`'s own lock file (never
/// a broad media-root probe). A later native startup reconciler can combine
/// this with `MeetingSplitServicing.operation(id:)` (which exposes every
/// sibling child's stage, including gaps and not-yet-started parts) to avoid
/// mislabeling an actively-processing split child as interrupted just
/// because it has no capture `recording.lock`.
public enum MeetingSplitOperationOwnership: Sendable, Equatable {
    case activelyOwned
    case notActive
}

// MARK: - Errors

public enum MeetingSplitServiceError: Error, Sendable, Equatable, LocalizedError {
    case sourceNotFound
    case sourceNotEligible(String)
    case sourceExpiredByRetention
    case titleCountMismatch(expected: Int, actual: Int)
    /// A caller retried an existing idempotency key with a different source,
    /// cuts, titles, or expected identity than the frozen operation. Detected
    /// before the source is ever fetched, so it also fires cleanly after the
    /// original source has been deleted.
    case requestConflict(existingOperationId: UUID)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "No saved meeting matches the given source id."
        case .sourceNotEligible(let reason):
            return "This recording cannot be split: \(reason)."
        case .sourceExpiredByRetention:
            return "This recording's audio has passed the configured retention window and cannot be split."
        case .titleCountMismatch(let expected, let actual):
            return "Expected \(expected) part title(s) for \(expected) cut(s), got \(actual)."
        case .requestConflict(let existingOperationId):
            return "A different split request already exists under this idempotency key (operation \(existingOperationId))."
        }
    }
}

// MARK: - Narrow saved-audio transcription seam

/// The minimal saved-audio STT surface `MeetingSplitService` needs from
/// `TranscriptionService`. Kept separate from the much larger
/// `TranscriptionServiceProtocol` family so tests can inject a small mock
/// instead of a second full transcription-service double. `TranscriptionService`
/// already implements both methods with this exact signature via
/// `SpeechEngineOverrideTranscriptionService`.
public protocol MeetingSplitAudioTranscribing: Sendable {
    func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription

    func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
}

extension TranscriptionService: MeetingSplitAudioTranscribing {}

// MARK: - Service

public protocol MeetingSplitServicing: Sendable {
    /// Read-only. No writes, migrations or lock files.
    func preview(sourceId: UUID, cutPointsMs: [Int]) async throws -> MeetingSplitPreview

    /// Creates (or resumes an interrupted creation of) the audio parts, then
    /// processes every saved id sequentially. Safe to call again with the same
    /// `idempotencyKey` after an interruption at any point, including after
    /// the original source has been deleted (once the operation has already
    /// committed). `expectedSourceIdentity`, when supplied, must match both
    /// the frozen request on a same-key retry and the freshly probed source
    /// on first creation.
    @discardableResult
    func createAndProcess(
        idempotencyKey: String,
        sourceId: UUID,
        cutPointsMs: [Int],
        titles: [String],
        expectedSourceIdentity: String?,
        onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)?
    ) async throws -> MeetingSplitOperation

    /// Resumes processing of an already-committed operation without touching
    /// audio creation. Used to retry after a transcription/automation failure
    /// or an interrupted process, including when the caller only knows the
    /// operation id from `operations(sourceId:)` after losing an in-memory
    /// receipt.
    @discardableResult
    func resumeProcessing(
        operationId: UUID,
        onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)?
    ) async throws -> MeetingSplitOperation

    func operation(id: UUID) throws -> MeetingSplitOperation?
    func operations(sourceId: UUID) throws -> [MeetingSplitOperation]

    /// Abandons a `.preparing` operation and removes any of its own
    /// positively-identified unpublished child folders. Refused once
    /// committed — see `MeetingSplitRepository.discard`.
    @discardableResult
    func discard(operationId: UUID) throws -> MeetingSplitOperation

    /// Whether `operationId` is currently being actively worked by some
    /// process. See `MeetingSplitOperationOwnership`.
    func operationOwnership(operationId: UUID) throws -> MeetingSplitOperationOwnership
}

extension MeetingSplitServicing {
    @discardableResult
    public func createAndProcess(
        idempotencyKey: String,
        sourceId: UUID,
        cutPointsMs: [Int],
        titles: [String],
        onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)? = nil
    ) async throws -> MeetingSplitOperation {
        try await createAndProcess(
            idempotencyKey: idempotencyKey,
            sourceId: sourceId,
            cutPointsMs: cutPointsMs,
            titles: titles,
            expectedSourceIdentity: nil,
            onProgress: onProgress
        )
    }
}

public final class MeetingSplitService: MeetingSplitServicing, @unchecked Sendable {
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let splitRepo: MeetingSplitRepositoryProtocol
    private let exporter: MeetingSplitAudioExporter
    private let transcriptionService: MeetingSplitAudioTranscribing
    private let completionService: SavedAudioAutoPromptCompletionServicing
    private let fileManager: FileManager
    private let meetingRecordingsRootURL: @Sendable () -> URL
    private let retentionConfig: @Sendable () -> MeetingAudioRetention
    private let speechEngineSelection: @Sendable () -> SpeechEngineSelection

    public init(
        transcriptionRepo: TranscriptionRepositoryProtocol,
        splitRepo: MeetingSplitRepositoryProtocol,
        transcriptionService: MeetingSplitAudioTranscribing,
        completionService: SavedAudioAutoPromptCompletionServicing,
        exporter: MeetingSplitAudioExporter = MeetingSplitAudioExporter(),
        fileManager: FileManager = .default,
        meetingRecordingsRootURL: @escaping @Sendable () -> URL = {
            URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
        },
        retentionConfig: @escaping @Sendable () -> MeetingAudioRetention = {
            UserDefaultsAppRuntimePreferences.meetingAudioRetention(persistMigration: false)
        },
        speechEngineSelection: @escaping @Sendable () -> SpeechEngineSelection = {
            SpeechEngineSelection.finalTranscription()
        }
    ) {
        self.transcriptionRepo = transcriptionRepo
        self.splitRepo = splitRepo
        self.transcriptionService = transcriptionService
        self.completionService = completionService
        self.exporter = exporter
        self.fileManager = fileManager
        self.meetingRecordingsRootURL = meetingRecordingsRootURL
        self.retentionConfig = retentionConfig
        self.speechEngineSelection = speechEngineSelection
    }

    // MARK: Preview

    public func preview(sourceId: UUID, cutPointsMs: [Int]) async throws -> MeetingSplitPreview {
        guard let source = try transcriptionRepo.fetch(id: sourceId) else {
            throw MeetingSplitServiceError.sourceNotFound
        }
        return try await Self.preview(source: source, cutPointsMs: cutPointsMs,
                                      retention: retentionConfig(), exporter: exporter, fileManager: fileManager)
    }

    /// Inspects saved audio without constructing speech or completion services.
    public static func preview(
        source: Transcription,
        cutPointsMs: [Int],
        retention: MeetingAudioRetention,
        exporter: MeetingSplitAudioExporter = MeetingSplitAudioExporter(),
        fileManager: FileManager = .default
    ) async throws -> MeetingSplitPreview {
        try validateSource(source, retention: retention, fileManager: fileManager)
        guard let folderURL = MeetingArtifactStore.sessionFolderURL(for: source) else {
            throw MeetingSplitServiceError.sourceNotEligible("no saved audio folder for this recording")
        }
        let inspection = try await exporter.inspectSource(sourceFolderURL: folderURL)
        let ranges = cutPointsMs.isEmpty
            ? [MeetingSplitSourceRange(startMs: 0, endMs: inspection.durationMs)]
            : try MeetingSplitGeometry.ranges(durationMs: inspection.durationMs, cutPointsMs: cutPointsMs)
        // `inspection.hasRaw*` only proves the file exists; export of that
        // track additionally requires a usable alignment (`finishCreating`
        // omits any optional track whose `sourceAlignment` entry is nil, see
        // `transcribeChild`'s and `sliceOptionalTrack`'s own gating). Missing
        // or corrupt metadata must never block splitting itself — it only
        // narrows these capability flags to canonical-only, exactly like the
        // export path's own `try?` fallback.
        let sourceAlignment = (try? MeetingRecordingMetadataStore.load(from: folderURL, fileManager: fileManager))?.sourceAlignment
            ?? MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil)
        let hasRawMicrophone = inspection.hasRawMicrophone && sourceAlignment.microphone != nil
        let hasRawSystem = inspection.hasRawSystem && sourceAlignment.system != nil
        // The cleaned mic is rendered 1:1 with the raw mic and shares its
        // alignment (see `finishCreating`'s `alignmentTrack`/`sliceOptionalTrack`
        // calls for the cleaned file), so its usability gates on the same
        // microphone alignment entry, not a separate one of its own.
        let hasCleanedMicrophone = inspection.hasCleanedMicrophone && sourceAlignment.microphone != nil
        return MeetingSplitPreview(
            sourceId: source.id,
            sourceTitle: source.effectiveDisplayTitle,
            totalDurationMs: inspection.durationMs,
            ranges: ranges,
            hasRawMicrophone: hasRawMicrophone,
            hasRawSystem: hasRawSystem,
            hasCleanedMicrophone: hasCleanedMicrophone,
            sourceIdentity: try Self.encodedIdentity(MeetingSplitSourceIdentity(source: source, inspection: inspection))
        )
    }

    // MARK: Create + process

    @discardableResult
    public func createAndProcess(
        idempotencyKey: String,
        sourceId: UUID,
        cutPointsMs: [Int],
        titles: [String],
        expectedSourceIdentity: String? = nil,
        onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)? = nil
    ) async throws -> MeetingSplitOperation {
        let existing = try splitRepo.operation(idempotencyKey: idempotencyKey)
        if let existing, !requestMatches(
            existing.request, sourceId: sourceId, cutPointsMs: cutPointsMs,
            titles: titles, expectedSourceIdentity: expectedSourceIdentity
        ) {
            throw MeetingSplitServiceError.requestConflict(existingOperationId: existing.id)
        }
        let rootURL = destinationRoot(for: existing)
        if existing == nil || existing?.status == .preparing {
            let source = try eligibleSource(sourceId: sourceId)
            try validateDestinationRoot(rootURL, sourceFolder: sessionFolderURL(for: source))
        }
        // Held for the whole call: no other caller (create, process, resume
        // or discard) can touch this same operation concurrently, whether it
        // already exists or is being minted for the first time by this exact
        // call. Keyed by `idempotencyKey`, not an id, so this covers the
        // very first call for a brand new key too.
        let lease = try MeetingSplitOperationLease.acquire(
            idempotencyKey: idempotencyKey, meetingRecordingsRootURL: rootURL)
        defer { lease.release() }

        let operation = try await createIfNeeded(
            idempotencyKey: idempotencyKey,
            sourceId: sourceId,
            cutPointsMs: cutPointsMs,
            titles: titles,
            expectedSourceIdentity: expectedSourceIdentity,
            rootURL: rootURL
        )
        return try await processAll(operation: operation, onProgress: onProgress)
    }

    @discardableResult
    public func resumeProcessing(
        operationId: UUID,
        onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)? = nil
    ) async throws -> MeetingSplitOperation {
        guard let existing = try splitRepo.operation(id: operationId) else {
            throw MeetingSplitRepositoryError.operationNotFound
        }
        let rootURL = destinationRoot(for: existing)
        let lease = try MeetingSplitOperationLease.acquire(
            idempotencyKey: existing.idempotencyKey, meetingRecordingsRootURL: rootURL)
        defer { lease.release() }

        // Re-read under the claim: another caller may have advanced this
        // operation between our unlocked lookup above and acquiring the lease.
        guard let operation = try splitRepo.operation(id: operationId) else {
            throw MeetingSplitRepositoryError.operationNotFound
        }
        return try await processAll(operation: operation, onProgress: onProgress)
    }

    public func operation(id: UUID) throws -> MeetingSplitOperation? {
        try splitRepo.operation(id: id)
    }

    public func operations(sourceId: UUID) throws -> [MeetingSplitOperation] {
        try splitRepo.operations(sourceId: sourceId)
    }

    @discardableResult
    public func discard(operationId: UUID) throws -> MeetingSplitOperation {
        guard let existing = try splitRepo.operation(id: operationId) else {
            throw MeetingSplitRepositoryError.operationNotFound
        }
        let rootURL = destinationRoot(for: existing)
        let operationLease = try MeetingSplitOperationLease.acquire(
            idempotencyKey: existing.idempotencyKey, meetingRecordingsRootURL: rootURL)
        defer { operationLease.release() }

        // Only clean up folders positively verified as this exact operation's
        // own, and only after acquiring the media-mutation lease, so no
        // export/materialize writer can be racing this removal.
        let mediaLease = try MeetingMediaMutationLease.acquire(roots: [rootURL])
        defer { mediaLease.release() }
        guard let current = try splitRepo.operation(id: operationId) else {
            throw MeetingSplitRepositoryError.operationNotFound
        }
        guard current.status == .preparing || current.status == .discarded else {
            throw MeetingSplitRepositoryError.operationNotPreparing(current: current.status)
        }
        for childId in current.childIds {
            try MeetingSplitChildFolderClaim.removeIfOwn(
                operationId: current.id, childId: childId,
                folderURL: childFolderURL(childId: childId, rootURL: rootURL), fileManager: fileManager
            )
        }
        return current.status == .discarded ? current : try splitRepo.discard(operationId: operationId)
    }

    public func operationOwnership(operationId: UUID) throws -> MeetingSplitOperationOwnership {
        guard let operation = try splitRepo.operation(id: operationId) else {
            throw MeetingSplitRepositoryError.operationNotFound
        }
        let isActive = try MeetingSplitOperationLease.isActivelyOwned(
            idempotencyKey: operation.idempotencyKey, meetingRecordingsRootURL: destinationRoot(for: operation))
        return isActive ? .activelyOwned : .notActive
    }

    // MARK: - Creation (audio phase)

    private func createIfNeeded(
        idempotencyKey: String,
        sourceId: UUID,
        cutPointsMs: [Int],
        titles: [String],
        expectedSourceIdentity: String?,
        rootURL: URL
    ) async throws -> MeetingSplitOperation {
        // Compare the caller's payload against any existing frozen request
        // for this key BEFORE touching the source at all. A committed match
        // returns immediately without requiring the source to still exist —
        // the whole point of a same-key retry after deletion. A mismatch
        // conflicts cleanly, also without requiring the source. The interior
        // cut points are always fully recoverable from an existing frozen
        // request's contiguous children (`children[1...].startMs`), so no
        // duration probe is needed to compare them.
        if let existing = try splitRepo.operation(idempotencyKey: idempotencyKey) {
            guard requestMatches(
                existing.request, sourceId: sourceId, cutPointsMs: cutPointsMs, titles: titles,
                expectedSourceIdentity: expectedSourceIdentity
            ) else {
                throw MeetingSplitServiceError.requestConflict(existingOperationId: existing.id)
            }
            guard existing.status == .preparing else {
                // `.committed`: durable retry, no source lookup required.
                // `.discarded`: returned as-is; `processAll` will reject it.
                return existing
            }
            return try await finishCreating(operation: existing, rootURL: rootURL)
        }

        let source = try eligibleSource(sourceId: sourceId)
        let folderURL = try sessionFolderURL(for: source)
        let inspection = try await exporter.inspectSource(sourceFolderURL: folderURL)
        let ranges = try MeetingSplitGeometry.ranges(durationMs: inspection.durationMs, cutPointsMs: cutPointsMs)
        guard titles.count == ranges.count else {
            throw MeetingSplitServiceError.titleCountMismatch(expected: ranges.count, actual: titles.count)
        }
        if let expectedSourceIdentity {
            guard expectedSourceIdentity == (try Self.encodedIdentity(MeetingSplitSourceIdentity(source: source, inspection: inspection))) else {
                throw MeetingSplitServiceError.sourceNotEligible("the recording's audio changed since it was last inspected")
            }
        }

        let request = MeetingSplitRequest(
            sourceId: source.id,
            expectedSourceIdentity: try Self.encodedIdentity(MeetingSplitSourceIdentity(source: source, inspection: inspection)),
            children: zip(titles, ranges).map { title, range in
                MeetingSplitChildRequest(title: title, startMs: range.startMs, endMs: range.endMs)
            },
            destinationRootPath: rootURL.path
        )
        let operation = try splitRepo.begin(idempotencyKey: idempotencyKey, request: request)
        guard operation.status == .preparing else {
            // Another caller committed this exact key between our lookup
            // above and this `begin` call. Since we hold the operation lease
            // for this key, that can only mean the lookup above raced a
            // concurrent first `begin` for the very same brand-new key
            // (never a different in-flight caller of *this* lease); the
            // request equality `begin` itself enforces still applies.
            return operation
        }
        return try await finishCreating(operation: operation, rootURL: rootURL)
    }

    /// `true` when `sourceId`/`cutPointsMs`/`titles`/`expectedSourceIdentity`
    /// (the caller's raw payload) describe exactly the same split as the
    /// already-frozen `request`. Never requires a duration probe: a frozen
    /// request's contiguous ranges make every interior cut point directly
    /// readable back off `request.children`.
    private func requestMatches(
        _ request: MeetingSplitRequest,
        sourceId: UUID,
        cutPointsMs: [Int],
        titles: [String],
        expectedSourceIdentity: String?
    ) -> Bool {
        guard request.sourceId == sourceId else { return false }
        guard request.children.map(\.title) == titles else { return false }
        guard request.children.dropFirst().map(\.startMs) == cutPointsMs else { return false }
        if let expectedSourceIdentity {
            guard request.expectedSourceIdentity == expectedSourceIdentity else { return false }
        }
        return true
    }

    /// Exports (or re-exports, for an interrupted earlier attempt at this
    /// same operation) audio for every fixed child id and publishes them.
    /// Captures the source snapshot once, before export, and compares that
    /// exact snapshot at publish time — never a snapshot re-fetched after
    /// export, which would compare "now" against "now" and detect nothing.
    private func finishCreating(operation: MeetingSplitOperation, rootURL: URL) async throws -> MeetingSplitOperation {
        let source = try eligibleSource(sourceId: operation.sourceId)
        let folderURL = try sessionFolderURL(for: source)
        let preExportSnapshot = MeetingSplitSourceSnapshot(source: source)

        // Held for the whole export + publish: this is the media-mutation
        // window the contract requires protecting against concurrent
        // deletion/retention cleanup of either the source or the destination
        // root.
        let lease = try MeetingMediaMutationLease.acquire(roots: [folderURL.deletingLastPathComponent(), rootURL])
        defer { lease.release() }

        // Recheck retention right before real work, not only at preview time.
        try assertNotExpiredByRetention(source: source)

        let inspection = try await exporter.inspectSource(sourceFolderURL: folderURL)
        guard try Self.encodedIdentity(MeetingSplitSourceIdentity(source: source, inspection: inspection))
            == operation.request.expectedSourceIdentity else {
            throw MeetingSplitServiceError.sourceNotEligible("the recording's audio changed since this split was prepared")
        }
        let sourceAlignment = (try? MeetingRecordingMetadataStore.load(from: folderURL, fileManager: fileManager))?.sourceAlignment
            ?? MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil)
        let selectedEngine = speechEngineSelection()
        // The operation's own frozen request already carries each child's
        // resolved `[startMs, endMs)`; no need to re-derive ranges.
        let ranges = operation.request.children.map { MeetingSplitSourceRange(startMs: $0.startMs, endMs: $0.endMs) }

        let childRequests: [MeetingSplitAudioChildRequest] = try operation.childIds.enumerated().map { index, childId in
            let folderURL = try MeetingSplitChildFolderClaim.claim(
                operationId: operation.id,
                childId: childId,
                folderURL: childFolderURL(childId: childId, rootURL: rootURL),
                fileManager: fileManager
            )
            return MeetingSplitAudioChildRequest(childId: childId, range: ranges[index], destinationFolderURL: folderURL)
        }
        let exported = try await exporter.export(
            sourceFolderURL: folderURL,
            sourceAlignment: sourceAlignment,
            children: childRequests
        )

        var prepared: [MeetingSplitPreparedChild] = []
        prepared.reserveCapacity(exported.count)
        for export in exported {
            let destinationFolderURL = childFolderURL(childId: export.childId, rootURL: rootURL)
            let alignment = MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: Self.alignmentTrack(from: export.rawMicrophone),
                system: Self.alignmentTrack(from: export.rawSystem)
            )
            try MeetingRecordingMetadataStore.save(
                MeetingRecordingMetadata(
                    sourceAlignment: alignment,
                    speechEngine: selectedEngine,
                    speechEngineWasCaptured: true
                ),
                folderURL: destinationFolderURL,
                fileManager: fileManager
            )
            prepared.append(
                MeetingSplitPreparedChild(
                    childId: export.childId,
                    filePath: destinationFolderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback).path,
                    meetingArtifactFolderPath: destinationFolderURL.path,
                    durationMs: export.playback.durationMs
                )
            )
        }

        // Revalidate under the lease and check cancellation immediately
        // before publication: the last two things that could still make
        // publish's own snapshot comparison fail.
        try Task.checkCancellation()
        try assertNotExpiredByRetention(source: source)
        guard try transcriptionRepo.fetch(id: source.id) != nil else {
            throw MeetingSplitRepositoryError.sourceMissingOrChanged
        }

        return try splitRepo.publish(
            operationId: operation.id,
            preparedChildren: prepared,
            expectedSource: preExportSnapshot
        )
    }

    // MARK: - Processing (per-child phase)

    private func processAll(
        operation initialOperation: MeetingSplitOperation,
        onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)?
    ) async throws -> MeetingSplitOperation {
        guard initialOperation.status == .committed else {
            throw MeetingSplitRepositoryError.operationNotCommitted(current: initialOperation.status)
        }
        var operation = initialOperation
        do {
            try await runProcessingLoop(operation: &operation, onProgress: onProgress)
        } catch {
            // Settle every unfinished sibling truthfully instead of silently
            // leaving it "processing" forever. A genuine `CancellationError`
            // (explicit stop; the in-flight child already marked itself
            // cancelled above before rethrowing) marks the rest `.cancelled`,
            // still retryable. Anything else — for example a fatal,
            // non-cancellation repository fault escaping the per-child
            // handling above (a `markChild*` call itself failing) — marks
            // them `.failed` with that same error's message instead, so a
            // real fault is never relabeled as a deliberate stop. Never
            // touches an already-`.automationCompleted` stage, and never
            // masks the original error: it is always rethrown below.
            let isCancellation = error is CancellationError
            for progress in operation.childProgress
            where progress.stage != .automationCompleted && progress.outcome == .none {
                if isCancellation {
                    _ = try? splitRepo.markChildCancelled(operationId: operation.id, childId: progress.childId, now: Date())
                } else {
                    _ = try? splitRepo.markChildFailed(
                        operationId: operation.id, childId: progress.childId,
                        errorMessage: error.localizedDescription, now: Date()
                    )
                }
            }
            throw error
        }
        return operation
    }

    /// The actual per-child loop, factored out only so `processAll` can wrap
    /// it in one `do`/`catch` that settles every unfinished sibling on any
    /// escape (see `processAll`). `operation` is `inout`: Swift's copy-in
    /// copy-out parameter passing writes it back to the caller on *every*
    /// exit, including a thrown error, so the catch above always observes
    /// this loop's most recent persisted state, never a stale snapshot.
    private func runProcessingLoop(
        operation: inout MeetingSplitOperation,
        onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)?
    ) async throws {
        for (index, childId) in operation.childIds.enumerated() {
            // Explicit cancellation stops starting further children; already
            // published audio and any completed stages are left untouched,
            // and every not-yet-started sibling remains visibly retryable
            // (still `.pendingTranscription`) on the next resume.
            try Task.checkCancellation()

            guard let progress = operation.childProgress.first(where: { $0.childId == childId }) else { continue }
            guard progress.stage != .automationCompleted else { continue }

            // Reports the operation's actual current stage for this child
            // after every persisted transition below, not just once at loop
            // entry: a caller driving native progress must see the real
            // transcribing/transcribed/automationPending/automationCompleted
            // sequence, not one stale snapshot that makes long-running work
            // look stuck.
            func emitCurrentStage() {
                guard let current = operation.childProgress.first(where: { $0.childId == childId }) else { return }
                onProgress?(
                    MeetingSplitProcessingProgress(
                        operationId: operation.id, childId: childId, childIndex: index,
                        childCount: operation.childIds.count, stage: current.stage
                    )
                )
            }

            emitCurrentStage()

            // A child deleted after publication is skipped, not recreated;
            // its last known progress remains exactly as recorded. Re-fetched
            // fresh on every iteration, never cached from an earlier loop
            // turn or an outer scope, so a concurrent deletion is always
            // observed before this child's own processing step runs.
            guard var child = try transcriptionRepo.fetch(id: childId) else { continue }

            do {
                // A durably persisted transcript (including an empty one from
                // successful silence) must never be re-run merely because the
                // operation's own stage lagged behind a crash. `nil` is the
                // only "never attempted" signal; an empty string is a
                // successful result.
                if child.rawTranscript == nil {
                    operation = try splitRepo.markChildTranscriptionStarted(operationId: operation.id, childId: childId, now: Date())
                    emitCurrentStage()
                    let folder = try sessionFolderURL(for: child)
                    child = try await transcribeChild(child, folderURL: folder, rootURL: folder.deletingLastPathComponent())
                }
                operation = try splitRepo.markChildTranscriptionSucceeded(operationId: operation.id, childId: childId, now: Date())
                emitCurrentStage()
            } catch is CancellationError {
                operation = try splitRepo.markChildCancelled(operationId: operation.id, childId: childId, now: Date())
                throw CancellationError()
            } catch {
                operation = try splitRepo.markChildFailed(
                    operationId: operation.id, childId: childId, errorMessage: error.localizedDescription, now: Date()
                )
                continue
            }

            do {
                operation = try splitRepo.markChildAutomationStarted(operationId: operation.id, childId: childId, now: Date())
                emitCurrentStage()
                let result = try await completionService.completeAutoPrompts(for: child)
                if result.hasFailures {
                    let message = result.outcomes.compactMap { outcome -> String? in
                        guard case .failed(let failureMessage) = outcome.status else { return nil }
                        return "\(outcome.promptName): \(failureMessage)"
                    }.joined(separator: "; ")
                    operation = try splitRepo.markChildFailed(operationId: operation.id, childId: childId, errorMessage: message, now: Date())
                } else {
                    operation = try splitRepo.markChildAutomationSucceeded(operationId: operation.id, childId: childId, now: Date())
                    emitCurrentStage()
                }
            } catch is CancellationError {
                operation = try splitRepo.markChildCancelled(operationId: operation.id, childId: childId, now: Date())
                throw CancellationError()
            } catch {
                operation = try splitRepo.markChildFailed(
                    operationId: operation.id, childId: childId, errorMessage: error.localizedDescription, now: Date()
                )
                continue
            }
        }
    }

    /// Reuses the existing saved-audio speech methods, choosing the route by
    /// whether this child actually has an aligned raw track: the archived
    /// meeting route silently produces zero source transcripts (not a
    /// failure) when both `sourceAlignment.microphone` and `.system` are nil,
    /// which would otherwise look like a successful empty transcription.
    /// Canonical-only children must use the single-file route instead.
    ///
    /// The media mutation lease is held only for this speech step, over the
    /// whole configured recordings root (not just this child's own folder):
    /// the simplest reuse of the existing root-scoped lease, at the
    /// documented cost that it also blocks unrelated meeting-audio deletion
    /// elsewhere in the library for the duration of this child's STT call. It
    /// is released before the completion/automation step below, which may
    /// call an LLM provider — never held across that provider wait.
    private func transcribeChild(
        _ child: Transcription,
        folderURL: URL,
        rootURL: URL
    ) async throws -> Transcription {
        let lease = try MeetingMediaMutationLease.acquire(roots: [rootURL])
        defer { lease.release() }

        try Task.checkCancellation()
        guard try transcriptionRepo.fetch(id: child.id) != nil else {
            throw TranscriptionCompletionError.recordingDeleted
        }
        let metadata = try MeetingRecordingMetadataStore.load(from: folderURL, fileManager: fileManager)
        let playbackURL = folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback)

        if metadata.sourceAlignment.microphone != nil || metadata.sourceAlignment.system != nil {
            let recording = try MeetingRecordingOutput.loadArchived(
                displayName: child.fileName,
                mixedAudioURL: playbackURL,
                durationSeconds: Double(child.durationMs ?? 0) / 1_000,
                fileManager: fileManager
            )
            return try await transcriptionService.retranscribeMeeting(
                existing: child, recording: recording, speechEngineOverride: nil, onProgress: nil
            )
        }
        return try await transcriptionService.retranscribe(
            existing: child,
            fileURL: playbackURL,
            source: .meeting,
            speechEngineOverride: metadata.speechEngine,
            onProgress: nil
        )
    }

    // MARK: - Eligibility and paths

    private func eligibleSource(sourceId: UUID) throws -> Transcription {
        guard let source = try transcriptionRepo.fetch(id: sourceId) else {
            throw MeetingSplitServiceError.sourceNotFound
        }
        try Self.validateSource(source, retention: retentionConfig(), fileManager: fileManager)
        return source
    }

    private static func validateSource(
        _ source: Transcription, retention: MeetingAudioRetention, fileManager: FileManager
    ) throws {
        guard source.sourceType == .meeting else {
            throw MeetingSplitServiceError.sourceNotEligible("only saved meetings can be split")
        }
        guard source.status == .completed || source.status == .error else {
            throw MeetingSplitServiceError.sourceNotEligible("recording is still processing")
        }
        guard !MeetingAudioFile.isFinalizationInProgress(for: source, fileManager: fileManager) else {
            throw MeetingSplitServiceError.sourceNotEligible("recording is awaiting transcription or recovery")
        }
        try assertNotExpiredByRetention(source: source, config: retention, fileManager: fileManager)
    }

    private func sessionFolderURL(for source: Transcription) throws -> URL {
        guard let folderURL = MeetingArtifactStore.sessionFolderURL(for: source) else {
            throw MeetingSplitServiceError.sourceNotEligible("no saved audio folder for this recording")
        }
        return folderURL
    }

    private func assertNotExpiredByRetention(source: Transcription) throws {
        try Self.assertNotExpiredByRetention(source: source, config: retentionConfig(), fileManager: fileManager)
    }

    private static func assertNotExpiredByRetention(
        source: Transcription, config: MeetingAudioRetention, fileManager: FileManager
    ) throws {
        let candidate = MeetingAudioRetentionPolicy.Candidate(
            id: source.id,
            hasAudioOnDisk: !(source.filePath?.isEmpty ?? true) || source.meetingArtifactFolderPath != nil,
            isCompleted: source.status == .completed,
            ageReferenceDate: source.createdAt,
            hasRecoveryLock: MeetingAudioFile.isFinalizationInProgress(for: source, fileManager: fileManager)
        )
        guard MeetingAudioRetentionPolicy.sweep([candidate], config: config, now: Date()).isEmpty else {
            throw MeetingSplitServiceError.sourceExpiredByRetention
        }
    }

    private func childFolderURL(childId: UUID, rootURL: URL) -> URL {
        rootURL.appendingPathComponent(childId.uuidString, isDirectory: true)
    }

    private static func alignmentTrack(from exported: MeetingSplitExportedTrack?) -> MeetingSourceAlignment.Track? {
        guard let exported else { return nil }
        let frameCount = Int64((Double(exported.durationMs) / 1_000 * exported.sampleRate).rounded())
        return MeetingSourceAlignment.Track(
            firstHostTime: nil,
            lastHostTime: nil,
            startOffsetMs: exported.startOffsetMs,
            writtenFrameCount: frameCount,
            timelineFrameCount: frameCount,
            sampleRate: exported.sampleRate
        )
    }

    /// Encodes `identity` into `MeetingSplitRequest.expectedSourceIdentity`'s
    /// opaque `String` storage (the durable schema's existing field type).
    /// Round-tripped only for equality comparison, never parsed back into a
    /// `MeetingSplitSourceIdentity`.
    private static func encodedIdentity(_ identity: MeetingSplitSourceIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    private func destinationRoot(for operation: MeetingSplitOperation?) -> URL {
        if let path = operation?.request.destinationRootPath {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return meetingRecordingsRootURL().resolvingSymlinksInPath().standardizedFileURL
    }

    private func validateDestinationRoot(_ root: URL, sourceFolder: URL) throws {
        let destination = root.resolvingSymlinksInPath().standardizedFileURL.path
        let source = sourceFolder.resolvingSymlinksInPath().standardizedFileURL.path
        guard destination != source, !destination.hasPrefix(source + "/") else {
            throw MeetingSplitAudioExportError.destinationOverlapsSource(destination: destination, source: source)
        }
    }
}

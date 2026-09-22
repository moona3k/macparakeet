import Foundation
import MacParakeetCore
import OSLog

@MainActor
final class MeetingTranscriptionQueue {
    struct Item: Equatable {
        let recording: MeetingRecordingOutput
        let transcriptionID: UUID
        /// Recording-flow generation that owns this completion's presentation.
        let recordingGeneration: Int
        let operationContext: ObservabilityOperationContext
        let trigger: TelemetryMeetingOperationTrigger?
        let liveWordCount: Int
        let liveTranscriptLagged: Bool
        let finalizationOwnershipLease: MeetingFinalizationOwnershipLease?

        init(
            recording: MeetingRecordingOutput,
            transcriptionID: UUID,
            recordingGeneration: Int,
            operationContext: ObservabilityOperationContext,
            trigger: TelemetryMeetingOperationTrigger?,
            liveWordCount: Int,
            liveTranscriptLagged: Bool,
            finalizationOwnershipLease: MeetingFinalizationOwnershipLease? = nil
        ) {
            self.recording = recording
            self.transcriptionID = transcriptionID
            self.recordingGeneration = recordingGeneration
            self.operationContext = operationContext
            self.trigger = trigger
            self.liveWordCount = liveWordCount
            self.liveTranscriptLagged = liveTranscriptLagged
            self.finalizationOwnershipLease = finalizationOwnershipLease
        }

        func withTranscriptionID(_ transcriptionID: UUID) -> Item {
            Item(
                recording: recording,
                transcriptionID: transcriptionID,
                recordingGeneration: recordingGeneration,
                operationContext: operationContext,
                trigger: trigger,
                liveWordCount: liveWordCount,
                liveTranscriptLagged: liveTranscriptLagged,
                finalizationOwnershipLease: finalizationOwnershipLease
            )
        }

        func withFinalizationOwnershipLease(
            _ lease: MeetingFinalizationOwnershipLease
        ) -> Item {
            Item(
                recording: recording,
                transcriptionID: transcriptionID,
                recordingGeneration: recordingGeneration,
                operationContext: operationContext,
                trigger: trigger,
                liveWordCount: liveWordCount,
                liveTranscriptLagged: liveTranscriptLagged,
                finalizationOwnershipLease: lease
            )
        }
    }

    struct Snapshot: Equatable {
        let activeItem: Item?
        let pendingCount: Int

        var totalCount: Int {
            (activeItem == nil ? 0 : 1) + pendingCount
        }
    }

    enum Completion {
        case success(item: Item, transcription: Transcription)
        case failure(item: Item, error: Error)
    }

    private enum ProcessingAdmission {
        case admitted(Item)
        case alreadyCompleted(Transcription)
    }

    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingTranscriptionQueue")
    private let transcriptionService: TranscriptionServiceProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let meetingRecordingSettlement: MeetingRecordingSettlement
    private let finalizationOwnershipClaimer: any MeetingFinalizationOwnershipClaiming

    private var pendingItems: [Item] = []
    private var activeItem: Item?
    private var activeTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var onStateChanged: ((Snapshot) -> Void)?
    var onCompletion: ((Completion) -> Void)?

    init(
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        meetingRecordingSettlement: MeetingRecordingSettlement,
        finalizationOwnershipClaimer: any MeetingFinalizationOwnershipClaiming =
            MeetingRecordingLockFileStore()
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        self.meetingRecordingSettlement = meetingRecordingSettlement
        self.finalizationOwnershipClaimer = finalizationOwnershipClaimer
    }

    var snapshot: Snapshot {
        Snapshot(activeItem: activeItem, pendingCount: pendingItems.count)
    }

    var queuedTranscriptionIDs: Set<UUID> {
        var ids = Set(pendingItems.map(\.transcriptionID))
        if let activeID = activeItem?.transcriptionID {
            ids.insert(activeID)
        }
        return ids
    }

    @discardableResult
    func enqueue(_ item: Item) async -> Bool {
        guard !containsQueuedTranscription(id: item.transcriptionID) else {
            logger.info(
                "queued_meeting_transcription_duplicate_dropped id=\(item.transcriptionID.uuidString, privacy: .public)"
            )
            await restoreFinalizationOwnershipIfNeeded(for: item)
            return false
        }
        pendingItems.append(item)
        notifyStateChanged()
        startNextIfNeeded()
        return true
    }

    func enqueueClaimingFinalizationOwnership(_ item: Item) async throws -> Bool {
        let ownershipClaimer = finalizationOwnershipClaimer
        let lease = try await Task.detached(priority: .userInitiated) {
            try ownershipClaimer.claimFinalizationOwnership(
                folderURL: item.recording.folderURL
            )
        }.value
        return await enqueue(item.withFinalizationOwnershipLease(lease))
    }

    func waitUntilIdle() async {
        guard activeItem != nil || !pendingItems.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func startNextIfNeeded() {
        guard activeTask == nil, activeItem == nil, !pendingItems.isEmpty else { return }
        let item = pendingItems.removeFirst()
        activeItem = item
        notifyStateChanged()

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.process(item)
        }
    }

    private func process(_ originalItem: Item) async {
        let preparationStartedAt = Date()
        appendDiagnostic(originalItem, stage: "prepare_row", outcome: "started")
        let item: Item
        do {
            switch try await ensureProcessingRow(for: originalItem) {
            case .admitted(let admittedItem):
                item = admittedItem
                appendDiagnostic(
                    admittedItem,
                    stage: "prepare_row",
                    outcome: "success",
                    startedAt: preparationStartedAt
                )
            case .alreadyCompleted(let transcription):
                appendDiagnostic(
                    originalItem,
                    stage: "prepare_row",
                    outcome: "already_completed",
                    startedAt: preparationStartedAt
                )
                logger.info(
                    "queued_meeting_transcription_already_completed id=\(transcription.id.uuidString, privacy: .public)"
                )
                await restoreFinalizationOwnershipIfNeeded(for: originalItem)
                finishActiveItem(nil)
                return
            }
            if activeItem?.transcriptionID != item.transcriptionID {
                activeItem = item
                notifyStateChanged()
            }
        } catch {
            appendDiagnostic(
                originalItem,
                stage: "prepare_row",
                outcome: "failure",
                startedAt: preparationStartedAt,
                error: error
            )
            logger.error(
                "queued_meeting_transcription_prepare_failed session=\(originalItem.recording.sessionID.uuidString, privacy: .public) error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            await restoreFinalizationOwnershipIfNeeded(for: originalItem)
            finishActiveItem(.failure(item: originalItem, error: error))
            return
        }

        let finalizationStartedAt = Date()
        appendDiagnostic(item, stage: "finalize_transcript", outcome: "started")
        let transcription: Transcription
        do {
            transcription = try await Observability.withOperationContext(item.operationContext) {
                try await transcriptionService.finalizeMeetingTranscription(
                    recording: item.recording,
                    updating: item.transcriptionID,
                    onProgress: nil
                )
            }
            appendDiagnostic(
                item,
                stage: "finalize_transcript",
                outcome: "success",
                startedAt: finalizationStartedAt
            )
        } catch {
            appendDiagnostic(
                item,
                stage: "finalize_transcript",
                outcome: error is CancellationError ? "cancelled" : "failure",
                startedAt: finalizationStartedAt,
                error: error
            )
            logger.error(
                "queued_meeting_transcription_failed session=\(item.recording.sessionID.uuidString, privacy: .public) error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            await markFailed(item, error: error)
            await restoreFinalizationOwnershipIfNeeded(for: item)
            finishActiveItem(.failure(item: item, error: error))
            return
        }

        let settlementStartedAt = Date()
        appendDiagnostic(item, stage: "settle_artifacts", outcome: "started")
        do {
            try await meetingRecordingSettlement.settleCompletedTranscription(
                folderURL: item.recording.folderURL,
                transcriptionID: transcription.id,
                sessionID: item.recording.sessionID
            )
            appendDiagnostic(
                item,
                stage: "settle_artifacts",
                outcome: "success",
                startedAt: settlementStartedAt
            )
        } catch {
            appendDiagnostic(
                item,
                stage: "settle_artifacts",
                outcome: "failure",
                startedAt: settlementStartedAt,
                error: error
            )
            logger.error(
                "queued_meeting_settlement_failed_lock_retained_for_recovery session=\(item.recording.sessionID.uuidString, privacy: .public) error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            await restoreFinalizationOwnershipIfNeeded(for: item)
        }
        finishActiveItem(.success(item: item, transcription: transcription))
    }

    private func ensureProcessingRow(for item: Item) async throws -> ProcessingAdmission {
        if let existing = try await fetchTranscription(id: item.transcriptionID) {
            guard existing.status != .completed else {
                return .alreadyCompleted(existing)
            }
            if existing.status != .processing || existing.errorMessage != nil {
                try await updateStatus(
                    id: item.transcriptionID,
                    status: .processing,
                    errorMessage: nil
                )
            }
            return .admitted(item)
        }

        let prepared = try await transcriptionService.prepareMeetingTranscription(
            recording: item.recording
        )
        guard prepared.status != .completed else {
            return .alreadyCompleted(prepared)
        }
        if prepared.status != .processing {
            try await updateStatus(
                id: prepared.id,
                status: .processing,
                errorMessage: nil
            )
        }
        return .admitted(item.withTranscriptionID(prepared.id))
    }

    private func markFailed(_ item: Item, error: Error) async {
        do {
            try await updateStatus(
                id: item.transcriptionID,
                status: error is CancellationError ? .cancelled : .error,
                errorMessage: error is CancellationError ? nil : error.localizedDescription
            )
        } catch {
            logger.error(
                "queued_meeting_status_update_failed id=\(item.transcriptionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func fetchTranscription(id: UUID) async throws -> Transcription? {
        let repo = transcriptionRepo
        return try await Task.detached(priority: .userInitiated) {
            try repo.fetch(id: id)
        }.value
    }

    private func updateStatus(
        id: UUID,
        status: Transcription.TranscriptionStatus,
        errorMessage: String?
    ) async throws {
        let repo = transcriptionRepo
        try await Task.detached(priority: .userInitiated) {
            try repo.updateStatus(id: id, status: status, errorMessage: errorMessage)
        }.value
    }

    private func containsQueuedTranscription(id: UUID) -> Bool {
        activeItem?.transcriptionID == id || pendingItems.contains { $0.transcriptionID == id }
    }

    private func restoreFinalizationOwnershipIfNeeded(for item: Item) async {
        guard let lease = item.finalizationOwnershipLease else { return }
        let ownershipClaimer = finalizationOwnershipClaimer
        do {
            try await Task.detached(priority: .utility) {
                try ownershipClaimer.releaseFinalizationOwnership(lease)
            }.value
        } catch {
            logger.error(
                "queued_meeting_ownership_release_failed id=\(item.transcriptionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func appendDiagnostic(
        _ item: Item,
        stage: String,
        outcome: String,
        startedAt: Date? = nil,
        error: Error? = nil
    ) {
        var fields =
            "meeting_transcription_queue_stage session=\(item.recording.sessionID.uuidString) transcription=\(item.transcriptionID.uuidString) stage=\(stage) outcome=\(outcome)"
        if let startedAt {
            fields += " duration_s=\(String(format: "%.3f", Date().timeIntervalSince(startedAt)))"
        }
        if let error {
            fields += " error_type=\(TelemetryErrorClassifier.classify(error))"
        }
        AudioCaptureDiagnostics.appendAsync(fields)
    }

    private func finishActiveItem(_ completion: Completion?) {
        activeTask = nil
        activeItem = nil
        if let completion {
            onCompletion?(completion)
        }
        notifyStateChanged()
        resumeIdleWaitersIfNeeded()
        startNextIfNeeded()
    }

    private func notifyStateChanged() {
        onStateChanged?(snapshot)
    }

    private func resumeIdleWaitersIfNeeded() {
        guard activeItem == nil, pendingItems.isEmpty, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

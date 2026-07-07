import Foundation
import MacParakeetCore
import OSLog

@MainActor
final class MeetingTranscriptionQueue {
    struct Item: Equatable {
        let recording: MeetingRecordingOutput
        let transcriptionID: UUID
        let operationContext: ObservabilityOperationContext
        let trigger: TelemetryMeetingOperationTrigger?
        let liveWordCount: Int
        let liveTranscriptLagged: Bool

        func withTranscriptionID(_ transcriptionID: UUID) -> Item {
            Item(
                recording: recording,
                transcriptionID: transcriptionID,
                operationContext: operationContext,
                trigger: trigger,
                liveWordCount: liveWordCount,
                liveTranscriptLagged: liveTranscriptLagged
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

    private var pendingItems: [Item] = []
    private var activeItem: Item?
    private var activeTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var onStateChanged: ((Snapshot) -> Void)?
    var onCompletion: ((Completion) -> Void)?

    init(
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        meetingRecordingSettlement: MeetingRecordingSettlement
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        self.meetingRecordingSettlement = meetingRecordingSettlement
    }

    var snapshot: Snapshot {
        Snapshot(activeItem: activeItem, pendingCount: pendingItems.count)
    }

    func enqueue(_ item: Item) {
        guard !containsQueuedTranscription(id: item.transcriptionID) else {
            logger.info(
                "queued_meeting_transcription_duplicate_dropped id=\(item.transcriptionID.uuidString, privacy: .public)"
            )
            return
        }
        pendingItems.append(item)
        notifyStateChanged()
        startNextIfNeeded()
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
        let item: Item
        do {
            switch try await ensureProcessingRow(for: originalItem) {
            case .admitted(let admittedItem):
                item = admittedItem
            case .alreadyCompleted(let transcription):
                logger.info(
                    "queued_meeting_transcription_already_completed id=\(transcription.id.uuidString, privacy: .public)"
                )
                finishActiveItem(nil)
                return
            }
            if activeItem?.transcriptionID != item.transcriptionID {
                activeItem = item
                notifyStateChanged()
            }
        } catch {
            logger.error(
                "queued_meeting_transcription_prepare_failed session=\(originalItem.recording.sessionID.uuidString, privacy: .public) error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            finishActiveItem(.failure(item: originalItem, error: error))
            return
        }

        let transcription: Transcription
        do {
            transcription = try await Observability.withOperationContext(item.operationContext) {
                try await transcriptionService.finalizeMeetingTranscription(
                    recording: item.recording,
                    updating: item.transcriptionID,
                    onProgress: nil
                )
            }
        } catch {
            logger.error(
                "queued_meeting_transcription_failed session=\(item.recording.sessionID.uuidString, privacy: .public) error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            await markFailed(item, error: error)
            finishActiveItem(.failure(item: item, error: error))
            return
        }

        do {
            try await meetingRecordingSettlement.settleCompletedTranscription(
                folderURL: item.recording.folderURL,
                transcriptionID: transcription.id,
                sessionID: item.recording.sessionID
            )
        } catch {
            logger.error(
                "queued_meeting_settlement_failed_lock_retained_for_recovery session=\(item.recording.sessionID.uuidString, privacy: .public) error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
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

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

    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingTranscriptionQueue")
    private let transcriptionService: TranscriptionServiceProtocol
    private let meetingRecordingService: MeetingRecordingServiceProtocol

    private var pendingItems: [Item] = []
    private var activeItem: Item?
    private var activeTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var onStateChanged: ((Snapshot) -> Void)?
    var onCompletion: ((Completion) -> Void)?

    init(
        transcriptionService: TranscriptionServiceProtocol,
        meetingRecordingService: MeetingRecordingServiceProtocol
    ) {
        self.transcriptionService = transcriptionService
        self.meetingRecordingService = meetingRecordingService
    }

    var snapshot: Snapshot {
        Snapshot(activeItem: activeItem, pendingCount: pendingItems.count)
    }

    func enqueue(_ item: Item) {
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

    private func process(_ item: Item) async {
        do {
            let transcription = try await Observability.withOperationContext(item.operationContext) {
                try await transcriptionService.finalizeMeetingTranscription(
                    recording: item.recording,
                    updating: item.transcriptionID,
                    onProgress: nil
                )
            }
            await meetingRecordingService.completeTranscription(for: item.recording)
            finishActiveItem(.success(item: item, transcription: transcription))
        } catch {
            logger.error(
                "queued_meeting_transcription_failed session=\(item.recording.sessionID.uuidString, privacy: .public) error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            await meetingRecordingService.finishTranscriptionAttempt(for: item.recording)
            finishActiveItem(.failure(item: item, error: error))
        }
    }

    private func finishActiveItem(_ completion: Completion) {
        activeTask = nil
        activeItem = nil
        onCompletion?(completion)
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

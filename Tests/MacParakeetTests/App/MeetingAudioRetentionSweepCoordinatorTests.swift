import XCTest
import MacParakeetCore
@testable import MacParakeet

@MainActor
final class MeetingAudioRetentionSweepCoordinatorTests: XCTestCase {
    func testLaunchSweepWaitsForRecoveryAndUsesPostRecoveryClock() async {
        let defaults = makeDefaults()
        let repository = RecordingTranscriptionRepository()
        let recoveryGate = AsyncGate()
        let recoveryTask = Task { await recoveryGate.wait() }
        let sweepNow = Date(timeIntervalSince1970: 2_000_000)
        let coordinator = MeetingAudioRetentionSweepCoordinator(
            defaults: defaults,
            now: { sweepNow },
            minimumSweepInterval: 24 * 60 * 60
        )

        coordinator.scheduleLaunchSweep(
            repository: repository,
            retention: .deleteAfterDays(7),
            after: recoveryTask
        )

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(repository.cutoffs.isEmpty)

        await recoveryGate.open()

        let didFetchAfterRecovery = await waitForFetch(repository)
        XCTAssertTrue(didFetchAfterRecovery)
        XCTAssertEqual(repository.cutoffs.first, sweepNow.addingTimeInterval(-7 * 24 * 60 * 60))
    }

    func testPreferenceChangeSweepWaitsForPendingLaunchRecovery() async {
        let defaults = makeDefaults()
        let repository = RecordingTranscriptionRepository()
        let recoveryGate = AsyncGate()
        let recoveryTask = Task { await recoveryGate.wait() }
        let sweepNow = Date(timeIntervalSince1970: 3_000_000)
        let coordinator = MeetingAudioRetentionSweepCoordinator(
            defaults: defaults,
            now: { sweepNow },
            minimumSweepInterval: 24 * 60 * 60
        )

        coordinator.scheduleLaunchSweep(
            repository: repository,
            retention: .keepForever,
            after: recoveryTask
        )
        coordinator.schedulePreferenceChangeSweep(
            repository: repository,
            retention: .deleteImmediately
        )

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(repository.cutoffs.isEmpty)

        await recoveryGate.open()

        let didFetchAfterRecovery = await waitForFetch(repository)
        XCTAssertTrue(didFetchAfterRecovery)
        XCTAssertEqual(repository.cutoffs.first, sweepNow)
    }

    func testForegroundSweepWaitsForPendingLaunchRecovery() async {
        let defaults = makeDefaults()
        let repository = RecordingTranscriptionRepository()
        let recoveryGate = AsyncGate()
        let recoveryTask = Task { await recoveryGate.wait() }
        let sweepNow = Date(timeIntervalSince1970: 4_000_000)
        let coordinator = MeetingAudioRetentionSweepCoordinator(
            defaults: defaults,
            now: { sweepNow },
            minimumSweepInterval: 24 * 60 * 60
        )

        coordinator.scheduleLaunchSweep(
            repository: repository,
            retention: .deleteAfterDays(7),
            after: recoveryTask
        )
        coordinator.scheduleForegroundSweepIfDue(
            repository: repository,
            retention: .deleteAfterDays(7)
        )

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(repository.cutoffs.isEmpty)

        await recoveryGate.open()

        let didFetchAfterRecovery = await waitForFetch(repository)
        XCTAssertTrue(didFetchAfterRecovery)
        XCTAssertEqual(repository.cutoffs.first, sweepNow.addingTimeInterval(-7 * 24 * 60 * 60))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "meeting-audio-retention-sweep-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitForFetch(
        _ repository: RecordingTranscriptionRepository,
        timeout: TimeInterval = 1.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !repository.cutoffs.isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RecordingTranscriptionRepository: TranscriptionRepositoryProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCutoffs: [Date] = []

    var cutoffs: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCutoffs
    }

    func fetchMeetingAudioRetentionCandidates(createdAtOrBefore cutoff: Date) throws -> [Transcription] {
        lock.lock()
        recordedCutoffs.append(cutoff)
        lock.unlock()
        return []
    }

    func save(_ transcription: Transcription) throws {}
    func fetch(id: UUID) throws -> Transcription? { nil }
    func fetchAll(limit: Int?) throws -> [Transcription] { [] }
    func delete(id: UUID) throws -> Bool { false }
    func deleteAll() throws {}
    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws {}
    func updateFileName(id: UUID, fileName: String) throws {}
    func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws {}
    func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws {}
    func updateFilePath(id: UUID, filePath: String?) throws {}
    func clearStoredAudioPathsForURLTranscriptions() throws {}
    @discardableResult
    func clearStoredAudioPathsForMeetingTranscriptions(under directoryPath: String) throws -> [UUID] { [] }
    func updateFavorite(id: UUID, isFavorite: Bool) throws {}
    func fetchFavorites() throws -> [Transcription] { [] }
}

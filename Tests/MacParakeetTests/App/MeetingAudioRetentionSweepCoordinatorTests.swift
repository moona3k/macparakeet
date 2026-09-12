import XCTest
@testable import MacParakeetCore
@testable import MacParakeet

@MainActor
final class MeetingAudioRetentionSweepCoordinatorTests: XCTestCase {
    func testHeldMediaLeaseKeepsSweepDueUntilNextForegroundTriggerAfterRelease() async throws {
        try await assertHeldMediaLeaseKeepsSweepDue(recentSuccessfulSweep: false)
    }

    func testFailedPreferenceSweepInvalidatesRecentSuccessForForegroundRetry() async throws {
        try await assertHeldMediaLeaseKeepsSweepDue(recentSuccessfulSweep: true)
    }

    private func assertHeldMediaLeaseKeepsSweepDue(recentSuccessfulSweep: Bool) async throws {
        let defaults = makeDefaults()
        let manager = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let folderURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let audioURL = folderURL.appendingPathComponent("meeting-playback.m4a")
        try Data("audio".utf8).write(to: audioURL)
        try Data("{}".utf8).write(to: MeetingRecordingMetadataStore.metadataURL(for: folderURL))
        let sweepNow = Date(timeIntervalSince1970: 4_000_000)
        let createdAt = sweepNow.addingTimeInterval(-31 * 24 * 60 * 60)
        let transcription = Transcription(
            createdAt: createdAt,
            fileName: "Meeting",
            filePath: audioURL.path,
            status: .completed,
            sourceType: .meeting,
            updatedAt: createdAt
        )
        try repository.save(transcription)
        let lastSweepKey = UserDefaultsAppRuntimePreferences.lastMeetingAudioRetentionSweepAtKey
        let previousSweep = sweepNow.addingTimeInterval(recentSuccessfulSweep ? -60 : -2 * 24 * 60 * 60)
        defaults.set(previousSweep, forKey: lastSweepKey)
        let coordinator = MeetingAudioRetentionSweepCoordinator(defaults: defaults, now: { sweepNow })
        let lease = try MeetingMediaMutationLease.acquire(roots: [rootURL])
        defer { lease.release() }

        let failedResult = try MeetingAudioRetentionSweeper(repository: repository)
            .sweep(retention: .deleteAfterDays(7), now: sweepNow)
        XCTAssertEqual(failedResult.failedCount, 1)
        if recentSuccessfulSweep {
            coordinator.schedulePreferenceChangeSweep(repository: repository, retention: .deleteAfterDays(7))
        } else {
            coordinator.scheduleForegroundSweepIfDue(repository: repository, retention: .deleteAfterDays(7))
        }
        await coordinator.sweepTask?.value

        XCTAssertNil(defaults.object(forKey: lastSweepKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(try repository.fetch(id: transcription.id)?.filePath, audioURL.path)

        lease.release()
        coordinator.scheduleForegroundSweepIfDue(repository: repository, retention: .deleteAfterDays(7))
        await coordinator.sweepTask?.value

        XCTAssertEqual(defaults.object(forKey: lastSweepKey) as? Date, sweepNow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        let retained = try XCTUnwrap(repository.fetch(id: transcription.id))
        XCTAssertNil(retained.filePath)
    }

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
            retention: .deleteAfterDays(7)
        )

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(repository.cutoffs.isEmpty)

        await recoveryGate.open()

        let didFetchAfterRecovery = await waitForFetch(repository)
        XCTAssertTrue(didFetchAfterRecovery)
        XCTAssertEqual(repository.cutoffs.first, sweepNow.addingTimeInterval(-7 * 24 * 60 * 60))
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
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
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

    func savePreservingUserMetadata(
        _ transcription: Transcription, originalFileName: String
    ) throws -> Transcription { throw TranscriptionCompletionError.recordingDeleted }

    func save(_ transcription: Transcription) throws {}
    func fetch(id: UUID) throws -> Transcription? { nil }
    func fetchAll(limit: Int?) throws -> [Transcription] { [] }
    func delete(id: UUID) throws -> Bool { false }
    func deleteAll() throws {}
    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws {}
    @discardableResult
    func updateFileName(id: UUID, fileName: String) throws -> Transcription? { nil }
    func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws {}
    func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws {}
    func updateFilePath(id: UUID, filePath: String?) throws {}
    func clearStoredAudioPathsForURLTranscriptions() throws {}
    @discardableResult
    func clearStoredAudioPathsForMeetingTranscriptions(under directoryPath: String) throws -> [UUID] { [] }
    func updateFavorite(id: UUID, isFavorite: Bool) throws {}
    func fetchFavorites() throws -> [Transcription] { [] }
}

import AVFoundation
import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingRecordingRecoveryServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var lockStore: RecoveryRecordingLockFileStore!
    private var transcriptionRepo: RecordingTranscriptionRepository!
    private var transcriptionService: RecoveryMockTranscriptionService!
    private var audioConverter: RecoveryMockAudioConverter!
    private var recoveryService: MeetingRecordingRecoveryService!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecordingRecoveryServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        lockStore = RecoveryRecordingLockFileStore(processChecker: RecoveryProcessChecker(alivePIDs: []))
        transcriptionRepo = RecordingTranscriptionRepository()
        transcriptionService = RecoveryMockTranscriptionService()
        audioConverter = RecoveryMockAudioConverter()
        recoveryService = MeetingRecordingRecoveryService(
            meetingsRoot: tempRoot,
            lockFileStore: lockStore,
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            audioConverter: audioConverter
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testRecoverSynthesizesMetadataAndPersistsRecoveredTranscription() async throws {
        let fixture = try makeRecoverableSession()

        let transcription = try await recoveryService.recover(fixture.lock)

        XCTAssertTrue(transcription.recoveredFromCrash)
        XCTAssertEqual(transcription.sourceType, .meeting)
        XCTAssertEqual(transcriptionRepo.saved.last?.recoveredFromCrash, true)
        XCTAssertEqual(transcriptionService.recordings.count, 1)
        XCTAssertEqual(transcriptionService.recordings.first?.sessionID, fixture.lock.sessionId)
        XCTAssertEqual(audioConverter.mixes.count, 1)

        let metadata = try MeetingRecordingMetadataStore.load(from: fixture.folderURL)
        XCTAssertNotNil(metadata.sourceAlignment.microphone)
        XCTAssertNotNil(metadata.sourceAlignment.system)
        XCTAssertEqual(metadata.sourceAlignment.microphone?.startOffsetMs, 0)
        XCTAssertEqual(metadata.sourceAlignment.system?.startOffsetMs, 0)
    }

    func testRecoverDeletesLockOnSuccess() async throws {
        let fixture = try makeRecoverableSession()

        _ = try await recoveryService.recover(fixture.lock)

        XCTAssertNil(try lockStore.read(folderURL: fixture.folderURL))
    }

    func testRecoverKeepsLockOnFailure() async throws {
        let fixture = try makeRecoverableSession()
        transcriptionService.errorToThrow = RecoveryTestError.transcriptionFailed

        do {
            _ = try await recoveryService.recover(fixture.lock)
            XCTFail("Expected recovery to throw")
        } catch {
            XCTAssertNotNil(try lockStore.read(folderURL: fixture.folderURL))
        }
    }

    func testRecoverContinuesWhenMixFails() async throws {
        let fixture = try makeRecoverableSession()
        audioConverter.errorToThrow = RecoveryTestError.mixFailed

        let recovered = try await recoveryService.recover(fixture.lock)

        XCTAssertTrue(recovered.recoveredFromCrash)
        XCTAssertNil(try lockStore.read(folderURL: fixture.folderURL))
        XCTAssertEqual(transcriptionService.recordings.count, 1)
        XCTAssertEqual(audioConverter.mixes.count, 1)
        XCTAssertEqual(audioConverter.mixes.first?.output, fixture.folderURL.appendingPathComponent("meeting.m4a"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.folderURL.appendingPathComponent("meeting.m4a").path),
            "failed playback mix should not block source-based transcription"
        )
    }

    func testRecoverRetryReusesSavedTranscriptWhenLockDeletePreviouslyFailed() async throws {
        let fixture = try makeRecoverableSession()
        lockStore.deleteErrorsRemaining = 1

        do {
            _ = try await recoveryService.recover(fixture.lock)
            XCTFail("Expected first recovery to fail deleting the lock")
        } catch {
            XCTAssertNotNil(try lockStore.read(folderURL: fixture.folderURL))
            XCTAssertEqual(transcriptionService.recordings.count, 1)
            XCTAssertEqual(transcriptionRepo.saved.count, 1)
        }

        audioConverter.errorToThrow = RecoveryTestError.mixFailed
        let recovered = try await recoveryService.recover(fixture.lock)

        XCTAssertTrue(recovered.recoveredFromCrash)
        XCTAssertNil(try lockStore.read(folderURL: fixture.folderURL))
        XCTAssertEqual(transcriptionService.recordings.count, 1)
        XCTAssertEqual(transcriptionRepo.saved.count, 1)
        XCTAssertEqual(audioConverter.mixes.count, 1)
    }

    func testRecoverSkipsCorruptSourceAndUsesRemainingPlayableAudio() async throws {
        let fixture = try makeRecoverableSession(systemAudio: .corrupt)

        let transcription = try await recoveryService.recover(fixture.lock)

        XCTAssertTrue(transcription.recoveredFromCrash)
        XCTAssertEqual(transcriptionService.recordings.count, 1)
        XCTAssertEqual(audioConverter.mixes.count, 1)
        XCTAssertEqual(audioConverter.mixes.first?.inputs.map(\.lastPathComponent), ["microphone.m4a"])
        let metadata = try MeetingRecordingMetadataStore.load(from: fixture.folderURL)
        XCTAssertNotNil(metadata.sourceAlignment.microphone)
        XCTAssertNil(metadata.sourceAlignment.system)
    }

    func testRecoverUsesAudioTrackSampleRateInRecoveredMetadata() async throws {
        let fixture = try makeRecoverableSession(
            microphoneSampleRate: 44_100,
            systemAudio: .corrupt
        )

        _ = try await recoveryService.recover(fixture.lock)

        let metadata = try MeetingRecordingMetadataStore.load(from: fixture.folderURL)
        let microphone = try XCTUnwrap(metadata.sourceAlignment.microphone)
        XCTAssertEqual(microphone.sampleRate, 44_100, accuracy: 1)
        XCTAssertEqual(Double(microphone.writtenFrameCount), 44_100, accuracy: 2_000)
    }

    func testRecoverCleansAwaitingTranscriptionLockWhenTranscriptAlreadyExists() async throws {
        let fixture = try makeRecoverableSession(lockState: .awaitingTranscription)
        let existing = Transcription(
            fileName: fixture.lock.displayName,
            filePath: fixture.folderURL.appendingPathComponent("meeting.m4a").path,
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(existing)

        let recovered = try await recoveryService.recover(fixture.lock)

        XCTAssertFalse(recovered.recoveredFromCrash)
        XCTAssertNil(try lockStore.read(folderURL: fixture.folderURL))
        XCTAssertTrue(audioConverter.mixes.isEmpty)
        XCTAssertTrue(transcriptionService.recordings.isEmpty)
    }

    func testDiscardRemovesEverything() async throws {
        let fixture = try makeRecoverableSession()

        try await recoveryService.discard(fixture.lock)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folderURL.path))
    }

    func testDiscardKeepsCompletedTranscriptAudioAndDeletesOnlyLock() async throws {
        let fixture = try makeRecoverableSession(lockState: .awaitingTranscription)
        let mixedURL = fixture.folderURL.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8))
        let existing = Transcription(
            fileName: fixture.lock.displayName,
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(existing)

        try await recoveryService.discard(fixture.lock)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedURL.path))
        XCTAssertNil(try lockStore.read(folderURL: fixture.folderURL))
        XCTAssertNotNil(try transcriptionRepo.fetch(id: existing.id))
    }

    func testRecoverRetryRemovesPreviousIncompleteRecoveryRow() async throws {
        let fixture = try makeRecoverableSession()
        let mixedURL = fixture.folderURL.appendingPathComponent("meeting.m4a")
        let stale = Transcription(
            fileName: fixture.lock.displayName,
            filePath: mixedURL.path,
            status: .error,
            sourceType: .meeting
        )
        try transcriptionRepo.save(stale)

        let recovered = try await recoveryService.recover(fixture.lock)

        XCTAssertTrue(recovered.recoveredFromCrash)
        let rows = try transcriptionRepo.fetchAll(limit: nil).filter {
            $0.sourceType == .meeting && $0.filePath == mixedURL.path
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, recovered.id)
        XCTAssertNotEqual(rows.first?.id, stale.id)
        XCTAssertEqual(rows.first?.status, .completed)
        XCTAssertTrue(rows.first?.recoveredFromCrash == true)
    }

    private enum SourceFixture {
        case valid
        case corrupt
    }

    // MARK: - ADR-020 §9 — recovered notes

    func testRecoverAppliesLockFileNotesToRecoveredTranscriptionUserNotes() async throws {
        let fixture = try makeRecoverableSession(notes: "key decision: ship Friday\nfollow up with QA")

        let transcription = try await recoveryService.recover(fixture.lock)

        XCTAssertTrue(transcription.recoveredFromCrash)
        XCTAssertEqual(transcription.userNotes, "key decision: ship Friday\nfollow up with QA")
    }

    func testRecoverDoesNotSetUserNotesWhenLockHasNone() async throws {
        let fixture = try makeRecoverableSession(notes: nil)

        let transcription = try await recoveryService.recover(fixture.lock)

        XCTAssertNil(transcription.userNotes, "lock with no notes leaves userNotes nil")
    }

    // MARK: - discoverPendingRecoveries - empty-session filter

    func testDiscoverFiltersStubSessionWithoutDeletingFolder() async throws {
        let stub = try makeEmptyStubSession()

        let pending = try await recoveryService.discoverPendingRecoveries()

        XCTAssertTrue(pending.isEmpty, "stub session with init-only audio should be filtered")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stub.folderURL.path),
            "discovery must not delete recording folders before explicit recover/discard"
        )
        XCTAssertNotNil(try lockStore.read(folderURL: stub.folderURL))
    }

    func testDiscoverFiltersSessionWithNoAudioFiles() async throws {
        let folderURL = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let lock = MeetingRecordingLockFile(
            sessionId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 42,
            displayName: "Empty Session",
            folderURL: folderURL
        )
        try lockStore.write(lock, folderURL: folderURL)

        let pending = try await recoveryService.discoverPendingRecoveries()

        XCTAssertTrue(pending.isEmpty, "session with no audio files should be filtered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertNotNil(try lockStore.read(folderURL: folderURL))
    }

    func testDiscoverKeepsSessionWithViableAudio() async throws {
        let viable = try makeRecoverableSession()

        let pending = try await recoveryService.discoverPendingRecoveries()

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.sessionId, viable.lock.sessionId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: viable.folderURL.path))
    }

    func testDiscoverFiltersOnlyEmptySessionsInMixedBatch() async throws {
        let viable = try makeRecoverableSession()
        let stub = try makeEmptyStubSession()

        let pending = try await recoveryService.discoverPendingRecoveries()

        XCTAssertEqual(pending.map(\.sessionId), [viable.lock.sessionId])
        XCTAssertTrue(FileManager.default.fileExists(atPath: viable.folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stub.folderURL.path))
        XCTAssertNotNil(try lockStore.read(folderURL: stub.folderURL))
    }

    func testDiscoverKeepsSessionWhenOnlyOneChannelHasViableAudio() async throws {
        // Recovery already supports single-channel sessions (mic only / system
        // only), so discovery shouldn't filter them either. Build a mic-only
        // session: real audio on the mic, init-stub system file.
        let folderURL = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try writeM4A(to: folderURL.appendingPathComponent("microphone.m4a"))
        try writeStubAudio(to: folderURL.appendingPathComponent("system.m4a"))
        let lock = MeetingRecordingLockFile(
            sessionId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 42,
            displayName: "Mic-only session",
            folderURL: folderURL
        )
        try lockStore.write(lock, folderURL: folderURL)

        let pending = try await recoveryService.discoverPendingRecoveries()

        XCTAssertEqual(pending.map(\.sessionId), [lock.sessionId])
    }

    func testDiscoverKeepsCompletedMeetingWhenSourceAudioIsMissing() async throws {
        let folderURL = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8))
        let existing = Transcription(
            fileName: "Recovered Team Sync",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(existing)
        let lock = MeetingRecordingLockFile(
            sessionId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 42,
            displayName: "Recovered Team Sync",
            state: .awaitingTranscription,
            folderURL: folderURL
        )
        try lockStore.write(lock, folderURL: folderURL)

        let pending = try await recoveryService.discoverPendingRecoveries()

        XCTAssertEqual(pending.map(\.sessionId), [lock.sessionId])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folderURL.path),
            "completed meeting audio must not be purged by the empty-session filter"
        )
    }

    func testDiscoverKeepsCandidateWhenViabilityCheckFails() async throws {
        let stub = try makeEmptyStubSession()
        transcriptionRepo.fetchAllError = RecoveryTestError.transcriptionFailed

        let pending = try await recoveryService.discoverPendingRecoveries()

        XCTAssertEqual(pending.map(\.sessionId), [stub.lock.sessionId])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stub.folderURL.path),
            "a viability-check failure should not purge user data"
        )
    }

    /// Writes a session folder containing only init-header-sized audio
    /// stubs - the exact pattern produced by a recording that was killed
    /// before any audio frames were captured. Real-world stub size is
    /// ~557 bytes; we go with a known-small fixed payload so the test is
    /// deterministic and obviously below `minViableAudioBytes`.
    private func makeEmptyStubSession() throws -> (folderURL: URL, lock: MeetingRecordingLockFile) {
        let sessionID = UUID()
        let folderURL = tempRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try writeStubAudio(to: folderURL.appendingPathComponent("microphone.m4a"))
        try writeStubAudio(to: folderURL.appendingPathComponent("system.m4a"))

        let lock = MeetingRecordingLockFile(
            sessionId: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 42,
            displayName: "Stub session",
            folderURL: folderURL
        )
        try lockStore.write(lock, folderURL: folderURL)
        return (folderURL, lock)
    }

    private func writeStubAudio(to url: URL) throws {
        // 600 bytes - comfortably above an empty file but well under
        // `minViableAudioBytes`. The exact byte content is irrelevant; we
        // only care that the file size is below the recovery threshold.
        try Data(count: 600).write(to: url)
    }

    private func makeRecoverableSession(
        microphoneSampleRate: Double = 48_000,
        systemAudio: SourceFixture = .valid,
        systemSampleRate: Double = 48_000,
        lockState: MeetingRecordingLockState = .recording,
        notes: String? = nil
    ) throws -> (folderURL: URL, lock: MeetingRecordingLockFile) {
        let sessionID = UUID()
        let folderURL = tempRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try writeM4A(
            to: folderURL.appendingPathComponent("microphone.m4a"),
            sampleRate: microphoneSampleRate
        )
        switch systemAudio {
        case .valid:
            try writeM4A(
                to: folderURL.appendingPathComponent("system.m4a"),
                sampleRate: systemSampleRate
            )
        case .corrupt:
            try Data("not audio".utf8).write(to: folderURL.appendingPathComponent("system.m4a"))
        }

        let lock = MeetingRecordingLockFile(
            sessionId: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 42,
            displayName: "Recovered Team Sync",
            state: lockState,
            notes: notes,
            folderURL: folderURL
        )
        try lockStore.write(lock, folderURL: folderURL)
        return (folderURL, lock)
    }

    private func writeM4A(to url: URL, sampleRate: Double = 48_000) throws {
        let frameCount = Int(sampleRate.rounded())
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            samples[index] = 0.1
        }
        try file.write(from: buffer)
    }

}

private enum RecoveryTestError: Error {
    case transcriptionFailed
    case lockDeleteFailed
    case mixFailed
}

private struct RecoveryProcessChecker: ProcessAliveChecking {
    let alivePIDs: Set<Int32>
    func isAlive(pid: Int32) -> Bool { alivePIDs.contains(pid) }
}

private final class RecoveryRecordingLockFileStore: MeetingRecordingLockFileStoring, @unchecked Sendable {
    private let delegate: MeetingRecordingLockFileStore
    private let lock = NSLock()
    var deleteErrorsRemaining = 0

    init(processChecker: ProcessAliveChecking) {
        self.delegate = MeetingRecordingLockFileStore(processChecker: processChecker)
    }

    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {
        try delegate.write(file, folderURL: folderURL)
    }

    func read(folderURL: URL) throws -> MeetingRecordingLockFile? {
        try delegate.read(folderURL: folderURL)
    }

    func delete(folderURL: URL) throws {
        let shouldThrow = lock.withLock {
            guard deleteErrorsRemaining > 0 else { return false }
            deleteErrorsRemaining -= 1
            return true
        }
        if shouldThrow {
            throw RecoveryTestError.lockDeleteFailed
        }
        try delegate.delete(folderURL: folderURL)
    }

    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] {
        try delegate.discoverOrphans(meetingsRoot: meetingsRoot)
    }
}

private final class RecoveryMockAudioConverter: AudioFileConverting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var mixes: [(inputs: [URL], output: URL)] = []
    var errorToThrow: Error?

    func convert(fileURL: URL) async throws -> URL { fileURL }

    func mixToM4A(
        inputURLs: [URL],
        outputURL: URL,
        sourceAlignment: MeetingSourceAlignment?
    ) async throws {
        lock.withLock {
            mixes.append((inputURLs, outputURL))
        }
        if let errorToThrow { throw errorToThrow }
        FileManager.default.createFile(atPath: outputURL.path, contents: Data("mixed".utf8))
    }
}

private final class RecoveryMockTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var recordings: [MeetingRecordingOutput] = []
    var errorToThrow: Error?

    func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        fatalError("Not used")
    }

    func transcribeMeeting(
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        if let errorToThrow { throw errorToThrow }
        lock.withLock {
            recordings.append(recording)
        }
        return Transcription(
            fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path,
            status: .completed,
            sourceType: .meeting
        )
    }

    func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        fatalError("Not used")
    }

    func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        fatalError("Not used")
    }

    func transcribeURL(
        urlString: String,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        fatalError("Not used")
    }
}

private final class RecordingTranscriptionRepository: TranscriptionRepositoryProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var saved: [Transcription] = []
    var fetchAllError: Error?

    func save(_ transcription: Transcription) throws {
        lock.withLock {
            saved.removeAll { $0.id == transcription.id }
            saved.append(transcription)
        }
    }

    func fetch(id: UUID) throws -> Transcription? {
        lock.withLock { saved.first { $0.id == id } }
    }

    func fetchAll(limit: Int?) throws -> [Transcription] {
        if let fetchAllError { throw fetchAllError }
        return lock.withLock { saved }
    }

    func fetchCompletedByVideoID(_ videoID: String) throws -> Transcription? { nil }
    func count() throws -> Int { lock.withLock { saved.count } }
    func search(query: String, limit: Int?) throws -> [Transcription] { [] }
    func delete(id: UUID) throws -> Bool {
        lock.withLock {
            let originalCount = saved.count
            saved.removeAll { $0.id == id }
            return saved.count != originalCount
        }
    }
    func deleteAll() throws {}
    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws {}
    func updateFileName(id: UUID, fileName: String) throws {}
    func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws {}
    func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws {}
    func clearStoredAudioPathsForURLTranscriptions() throws {}
    func updateFavorite(id: UUID, isFavorite: Bool) throws {}
    func fetchFavorites() throws -> [Transcription] { [] }
}

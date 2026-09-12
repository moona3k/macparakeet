import XCTest
@testable import MacParakeetCore

/// Coverage for the meeting-media mutation lease integration in
/// `TranscriptionAssetCleanup` (plan #895 U2a): saved-meeting audio
/// deletion/detach/bulk cleanup must hold the same lease a future split's
/// media export/materialize/publish will hold, across BOTH the file-removal
/// and the repository (row delete/detach) phases, while `recording.lock`
/// barriers and non-meeting/unmanaged behavior stay unchanged.
final class TranscriptionAssetCleanupMutationLeaseTests: XCTestCase {
    override func setUpWithError() throws {
        try AppPaths.ensureDirectories()
    }

    private func makeMeetingFolder() throws -> URL {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    private func meetingMutationRoot(for folderURL: URL) -> URL {
        folderURL.standardizedFileURL.deletingLastPathComponent()
    }

    // MARK: - deleteTranscription: both phases under one lease

    func testDeleteTranscriptionIsBlockedByAnExternallyHeldLeaseAndTouchesNeitherPhase() throws {
        let folderURL = try makeMeetingFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let mixedURL = folderURL.appendingPathComponent("meeting-playback.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))

        let transcription = Transcription(
            fileName: "Meeting", filePath: mixedURL.path, status: .completed, sourceType: .meeting)
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        // A future split (standing in here as an external holder) already
        // owns this recordings root.
        let externalLease = try MeetingMediaMutationLease.acquire(roots: [meetingMutationRoot(for: folderURL)])
        defer { externalLease.release() }

        XCTAssertThrowsError(try TranscriptionAssetCleanup.deleteTranscription(transcription, repository: repo)) {
            error in
            guard case MeetingMediaMutationLease.AcquisitionError.busy = error else {
                return XCTFail("Expected .busy while an external lease holds the root, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path), "folder must survive a blocked delete")
        XCTAssertEqual(repo.transcriptions.count, 1, "row must survive a blocked delete")
        XCTAssertTrue(repo.deleteCalledWith.isEmpty, "the row phase must never start while the lease is held elsewhere")
    }

    func testDeleteTranscriptionSucceedsAfterExternalLeaseIsReleased() throws {
        let folderURL = try makeMeetingFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let mixedURL = folderURL.appendingPathComponent("meeting-playback.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))

        let transcription = Transcription(
            fileName: "Meeting", filePath: mixedURL.path, status: .completed, sourceType: .meeting)
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        let externalLease = try MeetingMediaMutationLease.acquire(roots: [meetingMutationRoot(for: folderURL)])
        externalLease.release()

        XCTAssertTrue(try TranscriptionAssetCleanup.deleteTranscription(transcription, repository: repo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertEqual(repo.deleteCalledWith, [transcription.id])
    }

    // MARK: - detachOwnedMeetingAudio: already-existing both-phase behavior, now leased

    func testDetachOwnedMeetingAudioIsBlockedByAnExternallyHeldLease() throws {
        let folderURL = try makeMeetingFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let mixedURL = folderURL.appendingPathComponent("meeting-playback.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))

        let transcription = Transcription(
            fileName: "Meeting", filePath: mixedURL.path, status: .completed, sourceType: .meeting)
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        let externalLease = try MeetingMediaMutationLease.acquire(roots: [meetingMutationRoot(for: folderURL)])
        defer { externalLease.release() }

        XCTAssertThrowsError(
            try TranscriptionAssetCleanup.detachOwnedMeetingAudio(for: transcription, repository: repo)
        ) { error in
            guard case MeetingMediaMutationLease.AcquisitionError.busy = error else {
                return XCTFail("Expected .busy while an external lease holds the root, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedURL.path), "audio must survive a blocked detach")
        XCTAssertEqual(repo.transcriptions.first?.filePath, mixedURL.path, "row must survive a blocked detach")
    }

    // MARK: - clearManagedMeetingAudio: bulk file phase + bulk row phase together

    func testClearManagedMeetingAudioRemovesFilesAndDetachesRowsTogether() throws {
        let root = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mixedURL = session.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))

        let transcription = Transcription(
            fileName: "Meeting", filePath: mixedURL.path, status: .completed, sourceType: .meeting)
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        let clearedIDs = try TranscriptionAssetCleanup.clearManagedMeetingAudio(under: root.path, repository: repo)

        XCTAssertEqual(clearedIDs, [transcription.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mixedURL.path), "the file phase must have run")
        XCTAssertNil(repo.transcriptions.first?.filePath, "the row phase must have run")
    }

    func testClearManagedMeetingAudioIsBlockedByAnExternallyHeldLeaseAndTouchesNeitherPhase() throws {
        let root = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mixedURL = session.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))

        let transcription = Transcription(
            fileName: "Meeting", filePath: mixedURL.path, status: .completed, sourceType: .meeting)
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        let externalLease = try MeetingMediaMutationLease.acquire(roots: [root])
        defer { externalLease.release() }

        XCTAssertThrowsError(try TranscriptionAssetCleanup.clearManagedMeetingAudio(under: root.path, repository: repo)) {
            error in
            guard case MeetingMediaMutationLease.AcquisitionError.busy = error else {
                return XCTFail("Expected .busy while an external lease holds the root, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedURL.path))
        XCTAssertEqual(repo.transcriptions.first?.filePath, mixedURL.path)
    }

    // MARK: - recording.lock barrier is preserved (independent of the new lease)

    func testDeleteTranscriptionStillRefusesALockedMeetingFolder() throws {
        let folderURL = try makeMeetingFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let mixedURL = folderURL.appendingPathComponent("meeting-playback.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))
        let lockURL = MeetingRecordingLockFileStore.lockFileURL(for: folderURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))

        let transcription = Transcription(
            fileName: "Meeting", filePath: mixedURL.path, status: .processing, sourceType: .meeting)
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        XCTAssertThrowsError(try TranscriptionAssetCleanup.deleteTranscription(transcription, repository: repo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path), "a locked folder must survive")
        XCTAssertEqual(repo.transcriptions.count, 1, "the row must survive when the file phase refuses to proceed")
    }

    // MARK: - Non-meeting sources remain unaffected by the meeting-media lease

    func testDeleteTranscriptionForNonMeetingSourceIgnoresAnUnrelatedMeetingRootLease() throws {
        let downloadsURL = URL(fileURLWithPath: AppPaths.youtubeDownloadsDir, isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        let fileURL = downloadsURL.appendingPathComponent("\(UUID().uuidString).mp3")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data("audio".utf8)))

        let transcription = Transcription(
            fileName: "Podcast episode", filePath: fileURL.path, status: .completed, sourceType: .youtube)
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        // An unrelated meeting recordings root is held busy; a non-meeting
        // delete must never need or touch that lease.
        let unrelatedFolder = try makeMeetingFolder()
        defer { try? FileManager.default.removeItem(at: unrelatedFolder) }
        let unrelatedLease = try MeetingMediaMutationLease.acquire(roots: [meetingMutationRoot(for: unrelatedFolder)])
        defer { unrelatedLease.release() }

        XCTAssertTrue(try TranscriptionAssetCleanup.deleteTranscription(transcription, repository: repo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(repo.deleteCalledWith, [transcription.id])
    }
}

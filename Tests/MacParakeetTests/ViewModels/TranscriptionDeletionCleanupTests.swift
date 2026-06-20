import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class TranscriptionDeletionCleanupTests: XCTestCase {
    override func setUpWithError() throws {
        try AppPaths.ensureDirectories()
    }

    func testMeetingDeletionRemovesSessionFolder() throws {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        let micURL = folderURL.appendingPathComponent("microphone.m4a")
        FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8))
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let transcription = Transcription(
            fileName: "Meeting.m4a",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )

        try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testMeetingDeletionRefusesLockedAwaitingTranscriptionFolder() throws {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))
        try MeetingRecordingLockFileStore().write(
            MeetingRecordingLockFile(
                sessionId: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pid: 99,
                displayName: "Queued Meeting",
                state: .awaitingTranscription
            ),
            folderURL: folderURL
        )

        let transcription = Transcription(
            fileName: "Queued Meeting",
            filePath: mixedURL.path,
            status: .processing,
            sourceType: .meeting
        )

        XCTAssertThrowsError(try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedURL.path))
    }

    func testRemoveOwnedMeetingAudioReturnsTrueForStaleManagedPath() throws {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missingAudioURL = folderURL.appendingPathComponent("meeting.m4a")

        let transcription = Transcription(
            fileName: "Meeting.m4a",
            filePath: missingAudioURL.path,
            status: .completed,
            sourceType: .meeting
        )

        let removed = try TranscriptionDeletionCleanup.removeOwnedMeetingAudio(for: transcription)

        XCTAssertTrue(removed)
    }

    func testDetachMeetingAudioRemovesAudioBeforeRepositoryUpdate() throws {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))

        let transcription = Transcription(
            fileName: "Meeting",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]
        repo.updateFilePathError = NSError(domain: "test", code: 1)

        XCTAssertThrowsError(try TranscriptionAssetCleanup.detachOwnedMeetingAudio(
            for: transcription,
            repository: repo
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mixedURL.path))
        XCTAssertEqual(repo.transcriptions.first?.filePath, mixedURL.path)
        XCTAssertEqual(repo.transcriptions.first?.meetingArtifactFolderPath, folderURL.standardizedFileURL.path)
    }

    func testDetachMeetingAudioStoresArtifactFolderBeforeClearingAudioPath() throws {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))

        let transcription = Transcription(
            fileName: "Meeting",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        let result = try TranscriptionAssetCleanup.detachOwnedMeetingAudio(
            for: transcription,
            repository: repo
        )

        XCTAssertTrue(result.detached)
        let fetched = try XCTUnwrap(repo.transcriptions.first)
        XCTAssertNil(fetched.filePath)
        XCTAssertEqual(fetched.meetingArtifactFolderPath, folderURL.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mixedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testMeetingDeletionRemovesArtifactFolderAfterAudioWasDetached() throws {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: folderURL.appendingPathComponent("notes.md"))

        let transcription = Transcription(
            fileName: "Meeting",
            meetingArtifactFolderPath: folderURL.path,
            status: .completed,
            sourceType: .meeting
        )

        try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testBulkMeetingAudioCleanupRefusesLockedFolderBeforeRemovingAudio() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let healthyFolderURL = rootURL.appendingPathComponent("healthy", isDirectory: true)
        let lockedFolderURL = rootURL.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: healthyFolderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lockedFolderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let healthyAudioURL = healthyFolderURL.appendingPathComponent("meeting.m4a")
        let lockedAudioURL = lockedFolderURL.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: healthyAudioURL.path, contents: Data("mix".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: lockedAudioURL.path, contents: Data("mix".utf8)))
        try MeetingRecordingLockFileStore().write(
            MeetingRecordingLockFile(
                sessionId: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pid: 99,
                displayName: "Queued Meeting",
                state: .awaitingTranscription
            ),
            folderURL: lockedFolderURL
        )

        XCTAssertThrowsError(try TranscriptionAssetCleanup.removeManagedMeetingAudioFiles(under: rootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: healthyAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockedAudioURL.path))
    }

    func testBulkMeetingAudioCleanupThrowsWhenAudioRemovalFails() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let failingFolderURL = rootURL.appendingPathComponent("failing", isDirectory: true)
        try FileManager.default.createDirectory(at: failingFolderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let failingAudioURL = failingFolderURL.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: failingAudioURL.path, contents: Data("mix".utf8)))

        XCTAssertThrowsError(try TranscriptionAssetCleanup.removeManagedMeetingAudioFiles(
            under: rootURL.path,
            fileManager: ThrowingRemoveFileManager(failingURLs: [failingAudioURL])
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failingAudioURL.path))
    }

    func testDetachMeetingAudioKeepsFilePathWhenFileRemovalFails() throws {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8)))

        let transcription = Transcription(
            fileName: "Meeting",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [transcription]

        XCTAssertThrowsError(try TranscriptionAssetCleanup.detachOwnedMeetingAudio(
            for: transcription,
            repository: repo,
            fileManager: ThrowingRemoveFileManager(failingURLs: [mixedURL])
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedURL.path))
        XCTAssertEqual(repo.transcriptions.first?.filePath, mixedURL.path)
    }

    func testMeetingDeletionOutsideAppSupportIsIgnored() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8))

        let transcription = Transcription(
            fileName: "Meeting.m4a",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )

        try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        try? FileManager.default.removeItem(at: folderURL)
    }

    func testMeetingDeletionRemovesSessionFolderWithMetadataMarkerOutsideCurrentRoot() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8))
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: nil,
                system: nil
            )),
            folderURL: folderURL
        )

        let transcription = Transcription(
            fileName: "Meeting.m4a",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )

        try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testMeetingDeletionRemovesSessionFolderWithArtifactManifestOutsideCurrentRoot() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8))
        let manifestURL = folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName)
        try Data(#"{"schema":"com.macparakeet.meeting-session"}"#.utf8).write(to: manifestURL)

        let transcription = Transcription(
            fileName: "Meeting.m4a",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )

        try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testYouTubeDeletionRemovesDownloadedFileInsideAppSupport() throws {
        let fileURL = URL(fileURLWithPath: AppPaths.youtubeDownloadsDir, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("audio".utf8))

        let transcription = Transcription(
            fileName: "YouTube.m4a",
            filePath: fileURL.path,
            status: .completed,
            sourceType: .youtube
        )

        try TranscriptionAssetCleanup.removeOwnedAssets(for: transcription)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testYouTubeDeletionOutsideAppSupportIsIgnored() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("audio".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transcription = Transcription(
            fileName: "YouTube.m4a",
            filePath: fileURL.path,
            status: .completed,
            sourceType: .youtube
        )

        try TranscriptionAssetCleanup.removeOwnedAssets(for: transcription)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEmptyFilePathIsIgnored() throws {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        let transcription = Transcription(
            fileName: "Empty.m4a",
            filePath: "",
            status: .completed,
            sourceType: .youtube
        )

        try TranscriptionAssetCleanup.removeOwnedAssets(for: transcription)

        XCTAssertTrue(FileManager.default.fileExists(atPath: currentDirectory.path))
    }

}

private final class ThrowingRemoveFileManager: FileManager {
    private let failingPaths: Set<String>

    init(failingURLs: [URL]) {
        failingPaths = Set(failingURLs.map { $0.standardizedFileURL.path })
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if failingPaths.contains(url.standardizedFileURL.path) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

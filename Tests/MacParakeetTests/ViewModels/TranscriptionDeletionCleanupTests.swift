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

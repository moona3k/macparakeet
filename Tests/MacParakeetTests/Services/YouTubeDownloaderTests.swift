import XCTest
@testable import MacParakeetCore

final class YouTubeDownloaderTests: XCTestCase {
    func testDownloadInvalidURLThrows() async throws {
        let downloader = YouTubeDownloader()

        do {
            _ = try await downloader.download(url: "not-a-youtube-url")
            XCTFail("Should have thrown invalidURL")
        } catch let error as YouTubeDownloadError {
            if case .invalidURL = error {
                // Expected
            } else {
                XCTFail("Expected invalidURL, got \(error)")
            }
        }
    }

    func testDownloadEmptyURLThrows() async throws {
        let downloader = YouTubeDownloader()

        do {
            _ = try await downloader.download(url: "")
            XCTFail("Should have thrown invalidURL")
        } catch let error as YouTubeDownloadError {
            if case .invalidURL = error {
                // Expected
            } else {
                XCTFail("Expected invalidURL, got \(error)")
            }
        }
    }

    func testParseDownloadProgressPercentParsesYtDlpLine() {
        XCTAssertEqual(
            YouTubeDownloader.parseDownloadProgressPercent(from: "[download]  42.3% of ~12.34MiB at 1.23MiB/s ETA 00:07"),
            42
        )
        XCTAssertEqual(
            YouTubeDownloader.parseDownloadProgressPercent(from: "[download] 100% of 12.34MiB in 00:10"),
            100
        )
    }

    func testParseDownloadProgressPercentIgnoresNonProgressLine() {
        XCTAssertNil(YouTubeDownloader.parseDownloadProgressPercent(from: "[info] Downloading webpage"))
        XCTAssertNil(YouTubeDownloader.parseDownloadProgressPercent(from: "some random log line"))
    }

    func testSelectDownloadedAudioFileIgnoresYtDlpPartialArtifacts() {
        let uuid = UUID().uuidString

        XCTAssertEqual(
            YouTubeDownloader.selectDownloadedAudioFile(
                from: [
                    "\(uuid).m4a.part",
                    "\(uuid).m4a.ytdl",
                    "\(uuid).info.json",
                    "\(uuid).m4a",
                ],
                uuid: uuid
            ),
            "\(uuid).m4a"
        )
    }

    func testSelectDownloadedAudioFileReturnsNilWhenOnlyPartialArtifactsExist() {
        let uuid = UUID().uuidString

        XCTAssertNil(YouTubeDownloader.selectDownloadedAudioFile(
            from: [
                "\(uuid).webm.part",
                "\(uuid).webm.ytdl",
                "other-file.webm",
            ],
            uuid: uuid
        ))
    }

    func testSelectDownloadedAudioFileReturnsNilWhenOnlyNonAudioSidecarsExist() {
        let uuid = UUID().uuidString

        XCTAssertNil(YouTubeDownloader.selectDownloadedAudioFile(
            from: [
                "\(uuid).metadata",
                "\(uuid).json",
            ],
            uuid: uuid
        ))
    }

    func testRemoveDownloadArtifactsDeletesOnlyMatchingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-ytdlp-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let uuid = UUID().uuidString
        let matchingAudio = directory.appendingPathComponent("\(uuid).m4a")
        let matchingPartial = directory.appendingPathComponent("\(uuid).m4a.part")
        let unrelated = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: matchingAudio)
        try Data("partial".utf8).write(to: matchingPartial)
        try Data("other".utf8).write(to: unrelated)

        YouTubeDownloader.removeDownloadArtifacts(in: directory, uuid: uuid)

        XCTAssertFalse(FileManager.default.fileExists(atPath: matchingAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: matchingPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    // MARK: - DownloadResult Metadata Fields

    func testDownloadResultWithVideoMetadata() {
        let result = YouTubeDownloader.DownloadResult(
            audioFileURL: URL(fileURLWithPath: "/tmp/test.m4a"),
            title: "Swift Tutorial",
            durationSeconds: 600,
            channelName: "Swift Dev",
            thumbnailURL: "https://i.ytimg.com/vi/abc/maxresdefault.jpg",
            videoDescription: "Learn Swift"
        )
        XCTAssertEqual(result.channelName, "Swift Dev")
        XCTAssertEqual(result.thumbnailURL, "https://i.ytimg.com/vi/abc/maxresdefault.jpg")
        XCTAssertEqual(result.videoDescription, "Learn Swift")
    }

    func testDownloadResultMetadataDefaultsToNil() {
        let result = YouTubeDownloader.DownloadResult(
            audioFileURL: URL(fileURLWithPath: "/tmp/test.m4a"),
            title: "Video",
            durationSeconds: nil
        )
        XCTAssertNil(result.channelName)
        XCTAssertNil(result.thumbnailURL)
        XCTAssertNil(result.videoDescription)
    }

    func testPyInstallerLibraryValidationErrorDetection() {
        let error = YouTubeDownloadError.downloadFailed(
            "[PYI-5863:ERROR] Failed to load Python shared library '<path>': dlopen(<path>): code signature not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs"
        )

        XCTAssertTrue(YouTubeDownloader.isPyInstallerLibraryValidationError(error))
    }

    func testPyInstallerLibraryValidationErrorDetectionIgnoresOtherFailures() {
        XCTAssertFalse(YouTubeDownloader.isPyInstallerLibraryValidationError(
            YouTubeDownloadError.downloadFailed("ERROR: Video unavailable")
        ))
        XCTAssertFalse(YouTubeDownloader.isPyInstallerLibraryValidationError(
            YouTubeDownloadError.ytDlpNotFound
        ))
    }
}

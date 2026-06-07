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

    func testSupportedMediaURLAcceptsFacebookReel() {
        XCTAssertTrue(YouTubeDownloader.isSupportedMediaURL(
            "https://www.facebook.com/reel/1998924354042801"
        ))
    }

    func testSupportedMediaURLPreservesSchemalessYouTubeCompatibility() {
        XCTAssertTrue(YouTubeDownloader.isSupportedMediaURL(
            "youtube.com/watch?v=dQw4w9WgXcQ"
        ))
    }

    func testSupportedMediaURLRejectsNonHTTPInput() {
        XCTAssertFalse(YouTubeDownloader.isSupportedMediaURL("ftp://example.com/video.mp4"))
        XCTAssertFalse(YouTubeDownloader.isSupportedMediaURL("/tmp/video.mp4"))
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

    func testDownloadAudioArgumentsUseM4ASelector() {
        let args = YouTubeDownloader.downloadAudioArguments(
            ffmpegDir: "/opt/macparakeet/bin",
            outputTemplate: "/tmp/video.%(ext)s",
            url: "https://www.youtube.com/watch?v=abc",
            quality: .m4a
        )

        XCTAssertEqual(formatSelector(in: args), "bestaudio[ext=m4a]/bestaudio/best")
        XCTAssertEqual(args, [
            "--ffmpeg-location", "/opt/macparakeet/bin",
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "--no-playlist",
            "--retries", "3",
            "--concurrent-fragments", "4",
            "--embed-metadata",
            "--newline",
            "-o", "/tmp/video.%(ext)s",
            "--", "https://www.youtube.com/watch?v=abc",
        ])
    }

    func testDownloadAudioArgumentsUseBestAvailableSelector() {
        let args = YouTubeDownloader.downloadAudioArguments(
            ffmpegDir: "/opt/macparakeet/bin",
            outputTemplate: "/tmp/video.%(ext)s",
            url: "https://www.youtube.com/watch?v=abc",
            quality: .bestAvailable
        )

        XCTAssertEqual(formatSelector(in: args), "bestaudio/best")
        XCTAssertTrue(args.contains("--embed-metadata"))
        XCTAssertFalse(args.contains("--embed-thumbnail"))
        XCTAssertFalse(args.contains("--convert-thumbnails"))
    }

    func testDownloadAudioArgumentsIncludeJavaScriptRuntimeArgsBeforeFFmpeg() {
        let args = YouTubeDownloader.downloadAudioArguments(
            ffmpegDir: "/opt/macparakeet/bin",
            outputTemplate: "/tmp/video.%(ext)s",
            url: "https://www.youtube.com/watch?v=abc",
            quality: .m4a,
            javaScriptRuntimeArguments: ["--js-runtimes", "node:/opt/homebrew/bin/node"]
        )

        XCTAssertEqual(Array(args.prefix(4)), [
            "--no-js-runtimes",
            "--js-runtimes",
            "node:/opt/homebrew/bin/node",
            "--ffmpeg-location",
        ])
    }

    func testCommonYtDlpArgumentsShareJavaScriptRuntimeAndFFmpegPrefix() {
        XCTAssertEqual(
            YouTubeDownloader.commonYtDlpArguments(
                ffmpegDir: "/opt/macparakeet/bin",
                javaScriptRuntimeArguments: ["--js-runtimes", "node:/opt/homebrew/bin/node"]
            ),
            [
                "--no-js-runtimes",
                "--js-runtimes",
                "node:/opt/homebrew/bin/node",
                "--ffmpeg-location",
                "/opt/macparakeet/bin",
            ]
        )
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

    func testSelectDownloadedAudioFileAcceptsWebMForBestAvailableDownloads() {
        let uuid = UUID().uuidString

        XCTAssertEqual(
            YouTubeDownloader.selectDownloadedAudioFile(
                from: ["\(uuid).webm"],
                uuid: uuid
            ),
            "\(uuid).webm"
        )
    }

    func testSelectDownloadedAudioFileIgnoresUnsupportedAudioContainers() {
        let uuid = UUID().uuidString

        XCTAssertNil(YouTubeDownloader.selectDownloadedAudioFile(
            from: ["\(uuid).mka"],
            uuid: uuid
        ))
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

    func testReadableAudioFileStemUsesUploadDateChannelAndTitle() {
        let stem = YouTubeDownloader.readableAudioFileStem(
            title: "Swift/Tutorial: Part\n1",
            channelName: "Swift Dev",
            uploadDate: "20260515"
        )

        XCTAssertEqual(stem, "2026-05-15 - Swift Dev - Swift Tutorial Part 1")
    }

    func testReadableAudioFileStemPreservesMultilingualTitles() {
        let stem = YouTubeDownloader.readableAudioFileStem(
            title: "한국어 강의 / 中文播客: 日本語の話",
            channelName: "데브 채널",
            uploadDate: "20260515"
        )

        XCTAssertEqual(stem, "2026-05-15 - 데브 채널 - 한국어 강의 中文播客 日本語の話")
    }

    func testReadableAudioFileStemCapsByUTF8BytesWithoutBreakingCharacters() {
        let stem = YouTubeDownloader.readableAudioFileStem(
            title: String(repeating: "한국어", count: 80),
            channelName: nil,
            uploadDate: nil
        )

        XCTAssertLessThanOrEqual(stem.utf8.count, 180)
        XCTAssertFalse(stem.isEmpty)
        XCTAssertTrue(stem.allSatisfy { $0 == "한" || $0 == "국" || $0 == "어" })
    }

    func testReadableAudioFileStemFallsBackToYouTubeAudioWhenMetadataIsBlank() {
        let stem = YouTubeDownloader.readableAudioFileStem(
            title: "Untitled",
            channelName: " \n ",
            uploadDate: "not-a-date"
        )

        XCTAssertEqual(stem, "YouTube Audio")
    }

    func testReadableAudioFileURLDeduplicatesExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-ytdlp-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("2026-05-15 - Swift Dev - Swift Tutorial.m4a")
        try Data("existing".utf8).write(to: existing)

        let url = YouTubeDownloader.readableAudioFileURL(
            in: directory,
            title: "Swift Tutorial",
            channelName: "Swift Dev",
            uploadDate: "20260515",
            fileExtension: "m4a"
        )

        XCTAssertEqual(url.lastPathComponent, "2026-05-15 - Swift Dev - Swift Tutorial (1).m4a")
    }

    func testMoveDownloadedAudioToReadableURLRenamesRetainedAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-ytdlp-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("\(UUID().uuidString).webm")
        try Data("audio".utf8).write(to: source)

        let moved = try YouTubeDownloader.moveDownloadedAudioToReadableURL(
            source,
            title: "Swift Tutorial",
            channelName: "Swift Dev",
            uploadDate: "20260515"
        )

        XCTAssertEqual(moved.lastPathComponent, "2026-05-15 - Swift Dev - Swift Tutorial.webm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
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
            videoDescription: "Learn Swift",
            uploadDate: "20260515"
        )
        XCTAssertEqual(result.channelName, "Swift Dev")
        XCTAssertEqual(result.thumbnailURL, "https://i.ytimg.com/vi/abc/maxresdefault.jpg")
        XCTAssertEqual(result.videoDescription, "Learn Swift")
        XCTAssertEqual(result.uploadDate, "20260515")
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
        XCTAssertNil(result.uploadDate)
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

    private func formatSelector(in args: [String]) -> String? {
        guard let index = args.firstIndex(of: "-f"),
              args.indices.contains(args.index(after: index)) else {
            return nil
        }
        return args[args.index(after: index)]
    }
}

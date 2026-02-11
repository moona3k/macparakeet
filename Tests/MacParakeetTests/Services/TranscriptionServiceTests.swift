import XCTest
@testable import MacParakeetCore

private actor MockYouTubeDownloader: YouTubeDownloading {
    var downloadCallCount = 0
    var lastURL: String?
    private let result: YouTubeDownloader.DownloadResult

    init(result: YouTubeDownloader.DownloadResult) {
        self.result = result
    }

    func download(url: String) async throws -> YouTubeDownloader.DownloadResult {
        downloadCallCount += 1
        lastURL = url
        return result
    }
}

final class TranscriptionServiceTests: XCTestCase {
    var service: TranscriptionService!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        let dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        service = TranscriptionService(
            audioProcessor: mockAudio,
            sttClient: mockSTT,
            transcriptionRepo: transcriptionRepo
        )
    }

    func testTranscribeFileSucceeds() async throws {
        let expectedResult = STTResult(
            text: "This is a transcription",
            words: [
                TimestampedWord(word: "This", startMs: 0, endMs: 200, confidence: 0.99),
                TimestampedWord(word: "is", startMs: 210, endMs: 350, confidence: 0.98),
                TimestampedWord(word: "a", startMs: 360, endMs: 400, confidence: 0.97),
                TimestampedWord(word: "transcription", startMs: 410, endMs: 1000, confidence: 0.96),
            ]
        )
        await mockSTT.configure(result: expectedResult)

        let fileURL = URL(fileURLWithPath: "/tmp/test.mp3")
        let result = try await service.transcribe(fileURL: fileURL)

        XCTAssertEqual(result.fileName, "test.mp3")
        XCTAssertEqual(result.rawTranscript, "This is a transcription")
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.wordTimestamps?.count, 4)
        XCTAssertEqual(result.durationMs, 1000)

        // Verify saved to DB
        let fetched = try transcriptionRepo.fetch(id: result.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.status, .completed)
    }

    func testTranscribeFileError() async throws {
        await mockSTT.configure(error: STTError.transcriptionFailed("Model error"))

        let fileURL = URL(fileURLWithPath: "/tmp/test.mp3")

        do {
            _ = try await service.transcribe(fileURL: fileURL)
            XCTFail("Should have thrown")
        } catch let error as STTError {
            if case .transcriptionFailed(let reason) = error {
                XCTAssertEqual(reason, "Model error")
            } else {
                XCTFail("Expected transcriptionFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Verify error saved to DB
        let all = try transcriptionRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status, .error)
    }

    func testTranscribeURLWithoutDownloaderThrows() async throws {
        // Service without youtubeDownloader should throw
        do {
            _ = try await service.transcribeURL(urlString: "https://youtu.be/dQw4w9WgXcQ")
            XCTFail("Should have thrown")
        } catch let error as YouTubeDownloadError {
            if case .ytDlpNotFound = error {
                // Expected — no YouTubeDownloader configured
            } else {
                XCTFail("Expected ytDlpNotFound, got \(error)")
            }
        }
    }

    func testConvertCalledBeforeSTT() async throws {
        let expectedResult = STTResult(text: "Hello")
        await mockSTT.configure(result: expectedResult)

        let fileURL = URL(fileURLWithPath: "/tmp/test.mp3")
        _ = try await service.transcribe(fileURL: fileURL)

        let convertCount = await mockAudio.convertCallCount
        XCTAssertEqual(convertCount, 1)

        let lastURL = await mockAudio.lastConvertURL
        XCTAssertEqual(lastURL?.path, "/tmp/test.mp3")
    }

    func testTranscribeURLKeepsDownloadedAudioByDefault() async throws {
        let downloadedURL = try makeTempDownloadedAudio()
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        let downloader = MockYouTubeDownloader(result: YouTubeDownloader.DownloadResult(
            audioFileURL: downloadedURL,
            title: "Video",
            durationSeconds: 120
        ))

        let expectedResult = STTResult(text: "Downloaded transcript")
        await mockSTT.configure(result: expectedResult)

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttClient: mockSTT,
            transcriptionRepo: transcriptionRepo,
            youtubeDownloader: downloader
        )

        _ = try await service.transcribeURL(urlString: "https://youtu.be/dQw4w9WgXcQ")

        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedURL.path))
    }

    func testTranscribeURLDeletesDownloadedAudioWhenDisabled() async throws {
        let downloadedURL = try makeTempDownloadedAudio()
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        let downloader = MockYouTubeDownloader(result: YouTubeDownloader.DownloadResult(
            audioFileURL: downloadedURL,
            title: "Video",
            durationSeconds: 120
        ))

        let expectedResult = STTResult(text: "Downloaded transcript")
        await mockSTT.configure(result: expectedResult)

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttClient: mockSTT,
            transcriptionRepo: transcriptionRepo,
            shouldKeepDownloadedAudio: { false },
            youtubeDownloader: downloader
        )

        _ = try await service.transcribeURL(urlString: "https://youtu.be/dQw4w9WgXcQ")

        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedURL.path))
    }

    private func makeTempDownloadedAudio() throws -> URL {
        try AppPaths.ensureDirectories()
        let url = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent("downloaded-\(UUID().uuidString).m4a")
        let created = FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
        XCTAssertTrue(created)
        return url
    }
}

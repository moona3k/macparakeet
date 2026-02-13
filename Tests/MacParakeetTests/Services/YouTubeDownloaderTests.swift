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
}

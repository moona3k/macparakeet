import XCTest
@testable import MacParakeetCore

final class YouTubeDownloaderTests: XCTestCase {
    func testDownloadInvalidURLThrows() async throws {
        let downloader = YouTubeDownloader(pythonBootstrap: PythonBootstrap())

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
        let downloader = YouTubeDownloader(pythonBootstrap: PythonBootstrap())

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
}

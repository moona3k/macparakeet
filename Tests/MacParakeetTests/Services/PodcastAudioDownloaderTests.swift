import XCTest
@testable import MacParakeetCore

final class PodcastAudioDownloaderTests: XCTestCase {

    func testProgressPercent() {
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 50, total: 100), 50)
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 0, total: 100), 0)
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 100, total: 100), 100)
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 150, total: 100), 100, "clamped to 100")
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 50, total: 0), 0, "unknown total → 0")
    }

    func testSanitizedStem() {
        XCTAssertEqual(PodcastAudioDownloader.sanitizedStem("Ep 1: Hello / World"), "Ep 1 Hello World")
        XCTAssertEqual(PodcastAudioDownloader.sanitizedStem(nil), "Podcast Episode")
        XCTAssertEqual(PodcastAudioDownloader.sanitizedStem("   "), "Podcast Episode")
    }

    func testFileExtensionFromPathThenMime() {
        let mp3URL = URL(string: "https://cdn/x/ep705.mp3")!
        XCTAssertEqual(PodcastAudioDownloader.fileExtension(for: mp3URL, response: URLResponse()), "mp3")

        let noExtURL = URL(string: "https://cdn/x/stream?id=42")!
        let mp3Response = HTTPURLResponse(
            url: noExtURL, mimeType: "audio/mpeg", expectedContentLength: 0, textEncodingName: nil
        )
        XCTAssertEqual(PodcastAudioDownloader.fileExtension(for: noExtURL, response: mp3Response), "mp3")

        let m4aResponse = HTTPURLResponse(
            url: noExtURL, mimeType: "audio/mp4", expectedContentLength: 0, textEncodingName: nil
        )
        XCTAssertEqual(PodcastAudioDownloader.fileExtension(for: noExtURL, response: m4aResponse), "m4a")

        XCTAssertEqual(
            PodcastAudioDownloader.fileExtension(for: noExtURL, response: URLResponse()),
            "mp3",
            "unknown extension + no mime → mp3 default"
        )
    }

    func testUniqueOutputURLDeduplicates() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("podcast-dl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = PodcastAudioDownloader.uniqueOutputURL(in: dir, suggestedName: "Episode 1", fileExtension: "mp3")
        XCTAssertEqual(first.lastPathComponent, "Episode 1.mp3")
        FileManager.default.createFile(atPath: first.path, contents: Data("x".utf8))

        let second = PodcastAudioDownloader.uniqueOutputURL(in: dir, suggestedName: "Episode 1", fileExtension: "mp3")
        XCTAssertEqual(second.lastPathComponent, "Episode 1 (1).mp3", "dedupes with counter suffix")
    }
}

import XCTest
import MacParakeetCore
@testable import MacParakeet

final class TranscriptionSourceDisplayTests: XCTestCase {
    func testYouTubeURLDisplaysAsYouTube() {
        let transcription = Transcription(
            fileName: "youtube.m4a",
            sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            sourceType: .youtube
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        XCTAssertEqual(display, .youtube)
        XCTAssertEqual(display.collapsedText, "YouTube")
        XCTAssertEqual(display.expandedText, "YouTube source")
        XCTAssertNil(display.symbolText)
    }

    func testXURLDisplaysAsX() {
        let transcription = Transcription(
            fileName: "x.m4a",
            sourceURL: "https://x.com/macparakeet/status/1234567890123456789",
            sourceType: .youtube
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        XCTAssertEqual(display, .x)
        XCTAssertEqual(display.collapsedText, "X")
        XCTAssertEqual(display.expandedText, "X source")
        XCTAssertEqual(display.symbolText, "𝕏")
    }

    func testUnknownDownloaderURLDisplaysAsVideo() {
        let transcription = Transcription(
            fileName: "video.m4a",
            sourceURL: "https://example.com/watch/123",
            sourceType: .youtube
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        XCTAssertEqual(display, .mediaURL)
        XCTAssertEqual(display.collapsedText, "Video")
        XCTAssertEqual(display.expandedText, "Video source")
        XCTAssertNil(display.symbolText)
    }

    func testNonURLSourcesKeepExistingLabels() {
        let local = Transcription(fileName: "local.m4a", sourceType: .file)
        let meeting = Transcription(fileName: "Team Sync", sourceType: .meeting)

        XCTAssertEqual(TranscriptionSourceDisplay.resolve(for: local).collapsedText, "Local")
        XCTAssertEqual(TranscriptionSourceDisplay.resolve(for: meeting).collapsedText, "Meeting")
    }
}

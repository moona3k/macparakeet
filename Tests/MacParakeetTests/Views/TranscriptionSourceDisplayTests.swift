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

    func testPodcastDisplaysAsPodcast() {
        let transcription = Transcription(
            fileName: "podcast.m4a",
            sourceURL: "https://podcasts.apple.com/us/podcast/show/id123?i=456",
            sourceType: .podcast
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        XCTAssertEqual(display, .podcast)
        XCTAssertEqual(display.collapsedText, "Podcast")
        XCTAssertEqual(display.expandedText, "Podcast episode")
        XCTAssertNil(display.symbolText)
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

    func testSoundCloudURLDisplaysAsAudio() {
        let transcription = Transcription(
            fileName: "track.m4a",
            sourceURL: "https://soundcloud.com/artist/some-track",
            sourceType: .youtube
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        // SoundCloud is audio-first — it must not show the generic Video badge.
        XCTAssertEqual(display, .audioURL)
        XCTAssertEqual(display.collapsedText, "Audio")
        XCTAssertEqual(display.expandedText, "Audio source")
        XCTAssertNil(display.symbolText)
    }

    func testNonURLSourcesKeepExistingLabels() {
        let local = Transcription(fileName: "local.m4a", sourceType: .file)
        let meeting = Transcription(fileName: "Team Sync", sourceType: .meeting)

        XCTAssertEqual(TranscriptionSourceDisplay.resolve(for: local).collapsedText, "Local")
        XCTAssertEqual(TranscriptionSourceDisplay.resolve(for: meeting).collapsedText, "Meeting")
    }

    // MARK: - Which sources can drop their text

    /// The text is dropped only where a bundled brand mark replaces it. If an
    /// asset goes missing this fails here rather than shipping a blank label.
    @MainActor
    func testBrandedSourcesShipAMarkThatCanReplaceTheirText() throws {
        for display in [TranscriptionSourceDisplay.youtube, .x, .vimeo, .facebook, .tiktok, .instagram] {
            let platform = try XCTUnwrap(
                display.brandedPlatform,
                "\(display.collapsedText) must name the platform whose mark identifies it"
            )
            XCTAssertNotNil(
                BrandGlyphImage.image(for: platform),
                "\(display.collapsedText) claims a brand mark but no asset is bundled for it"
            )
        }
    }

    /// The SF Symbol fallback cannot stand alone: these all draw the same play
    /// rectangle and are separated only by tint, so anything without a bundled
    /// mark must keep its word.
    func testUnbrandedSourcesKeepTheirTextBecauseTheGlyphIsShared() {
        let shareOneGlyph: [TranscriptionSourceDisplay] = [.youtube, .x, .vimeo, .facebook, .tiktok, .instagram, .mediaURL]
        XCTAssertEqual(
            Set(shareOneGlyph.map(\.systemImage)),
            ["play.rectangle.fill"],
            "The SF Symbol path names no platform, which is why it never drops its text"
        )

        for display in [TranscriptionSourceDisplay.meeting, .localFile, .podcast, .audioURL, .mediaURL] {
            XCTAssertNil(
                display.brandedPlatform,
                "\(display.collapsedText) is ambiguous or unbranded and must keep its text"
            )
        }
    }

}

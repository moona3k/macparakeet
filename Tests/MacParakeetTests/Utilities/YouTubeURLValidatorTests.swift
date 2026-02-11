import XCTest
@testable import MacParakeetCore

final class YouTubeURLValidatorTests: XCTestCase {

    // MARK: - Valid URLs

    func testStandardWatchURL() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testWatchURLWithoutWWW() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testMobileURL() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://m.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://m.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testShortURL() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testShortsURL() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://www.youtube.com/shorts/dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testEmbedURL() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://www.youtube.com/embed/dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testVURL() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://www.youtube.com/v/dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://www.youtube.com/v/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testHTTPURL() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("http://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testURLWithoutProtocol() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testURLWithExtraParams() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42"), "dQw4w9WgXcQ")
    }

    func testVideoIDWithDashAndUnderscore() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("https://youtu.be/Ab-C_d3F-gH"))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("https://youtu.be/Ab-C_d3F-gH"), "Ab-C_d3F-gH")
    }

    // MARK: - Invalid URLs

    func testEmptyString() {
        XCTAssertFalse(YouTubeURLValidator.isYouTubeURL(""))
        XCTAssertNil(YouTubeURLValidator.extractVideoID(""))
    }

    func testWhitespaceOnly() {
        XCTAssertFalse(YouTubeURLValidator.isYouTubeURL("   "))
        XCTAssertNil(YouTubeURLValidator.extractVideoID("   "))
    }

    func testNonYouTubeURL() {
        XCTAssertFalse(YouTubeURLValidator.isYouTubeURL("https://vimeo.com/12345"))
        XCTAssertNil(YouTubeURLValidator.extractVideoID("https://vimeo.com/12345"))
    }

    func testPlainText() {
        XCTAssertFalse(YouTubeURLValidator.isYouTubeURL("not a url"))
    }

    func testYouTubeHomepage() {
        XCTAssertFalse(YouTubeURLValidator.isYouTubeURL("https://www.youtube.com"))
    }

    func testTooShortVideoID() {
        XCTAssertFalse(YouTubeURLValidator.isYouTubeURL("https://youtu.be/short"))
    }

    func testFilePath() {
        XCTAssertFalse(YouTubeURLValidator.isYouTubeURL("/Users/test/video.mp4"))
    }

    // MARK: - Whitespace handling

    func testURLWithLeadingTrailingWhitespace() {
        XCTAssertTrue(YouTubeURLValidator.isYouTubeURL("  https://youtu.be/dQw4w9WgXcQ  "))
        XCTAssertEqual(YouTubeURLValidator.extractVideoID("  https://youtu.be/dQw4w9WgXcQ  "), "dQw4w9WgXcQ")
    }
}

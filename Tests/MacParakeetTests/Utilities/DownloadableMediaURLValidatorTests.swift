import XCTest
@testable import MacParakeetCore

final class DownloadableMediaURLValidatorTests: XCTestCase {
    func testAcceptsHTTPSMediaURL() {
        XCTAssertTrue(DownloadableMediaURLValidator.isDownloadableMediaURL(
            "https://www.facebook.com/reel/1998924354042801"
        ))
    }

    func testAcceptsHTTPMediaURL() {
        XCTAssertTrue(DownloadableMediaURLValidator.isDownloadableMediaURL(
            "http://example.com/video.mp4"
        ))
    }

    func testAcceptsLenientHTTPURLWithUnencodedQueryCharacters() {
        XCTAssertTrue(DownloadableMediaURLValidator.isDownloadableMediaURL(
            "https://example.com/watch?metadata={abc}"
        ))
    }

    func testTrimsOuterWhitespace() {
        XCTAssertTrue(DownloadableMediaURLValidator.isDownloadableMediaURL(
            "  https://example.com/video.mp4\n"
        ))
    }

    func testRejectsLocalFilesAndUnsupportedSchemes() {
        XCTAssertFalse(DownloadableMediaURLValidator.isDownloadableMediaURL("/tmp/video.mp4"))
        XCTAssertFalse(DownloadableMediaURLValidator.isDownloadableMediaURL("video.mp4"))
        XCTAssertFalse(DownloadableMediaURLValidator.isDownloadableMediaURL("ftp://example.com/video.mp4"))
        XCTAssertFalse(DownloadableMediaURLValidator.isDownloadableMediaURL("https://"))
        XCTAssertFalse(DownloadableMediaURLValidator.isDownloadableMediaURL("https:///video.mp4"))
        XCTAssertFalse(DownloadableMediaURLValidator.isDownloadableMediaURL("https://?id=1"))
    }

    func testRejectsWhitespaceBearingInput() {
        XCTAssertFalse(DownloadableMediaURLValidator.isDownloadableMediaURL(
            "https://example.com/video one.mp4"
        ))
    }
}

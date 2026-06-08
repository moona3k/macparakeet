import XCTest
@testable import MacParakeetCore

final class XURLValidatorTests: XCTestCase {

    // MARK: - Valid URLs

    func testStandardStatusURL() {
        XCTAssertTrue(XURLValidator.isXURL("https://x.com/jack/status/20"))
    }

    func testTwitterStatusURL() {
        XCTAssertTrue(XURLValidator.isXURL("https://twitter.com/jack/status/20"))
    }

    func testWWWHosts() {
        XCTAssertTrue(XURLValidator.isXURL("https://www.x.com/user/status/1234567890123456789"))
        XCTAssertTrue(XURLValidator.isXURL("https://www.twitter.com/user/status/123"))
    }

    func testMobileHosts() {
        XCTAssertTrue(XURLValidator.isXURL("https://mobile.x.com/user/status/123"))
        XCTAssertTrue(XURLValidator.isXURL("https://mobile.twitter.com/user/status/123"))
    }

    func testIStatusURL() {
        XCTAssertTrue(XURLValidator.isXURL("https://x.com/i/status/123456"))
    }

    func testHTTPScheme() {
        XCTAssertTrue(XURLValidator.isXURL("http://x.com/user/status/123"))
    }

    func testURLWithoutProtocol() {
        XCTAssertTrue(XURLValidator.isXURL("x.com/user/status/123"))
    }

    func testURLWithQueryParams() {
        XCTAssertTrue(XURLValidator.isXURL("https://x.com/user/status/123?t=abc&s=20"))
    }

    func testURLWithMediaSubPath() {
        XCTAssertTrue(XURLValidator.isXURL("https://x.com/user/status/123/photo/1"))
    }

    func testTrailingSlash() {
        XCTAssertTrue(XURLValidator.isXURL("https://x.com/user/status/123/"))
    }

    func testLeadingTrailingWhitespace() {
        XCTAssertTrue(XURLValidator.isXURL("  https://x.com/user/status/123  "))
    }

    func testStatusUsername() {
        // Username literally "status" must still validate (the real @status account).
        XCTAssertTrue(XURLValidator.isXURL("https://x.com/status/status/123456"))
    }

    // MARK: - Invalid URLs

    func testEmptyString() {
        XCTAssertFalse(XURLValidator.isXURL(""))
    }

    func testWhitespaceOnly() {
        XCTAssertFalse(XURLValidator.isXURL("   "))
    }

    func testProfileURLWithoutStatus() {
        XCTAssertFalse(XURLValidator.isXURL("https://x.com/jack"))
    }

    func testBareHost() {
        XCTAssertFalse(XURLValidator.isXURL("https://x.com"))
    }

    func testStatusWithoutID() {
        XCTAssertFalse(XURLValidator.isXURL("https://x.com/user/status/"))
    }

    func testNonNumericID() {
        XCTAssertFalse(XURLValidator.isXURL("https://x.com/user/status/abc"))
    }

    func testNonASCIIDigitTweetIDRejected() {
        // Real tweet ids are ASCII digits; Arabic-Indic digits must not pass.
        XCTAssertFalse(XURLValidator.isXURL("https://x.com/user/status/١٢٣"))
    }

    func testYouTubeURLIsRejected() {
        XCTAssertFalse(XURLValidator.isXURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testLookalikeHostIsRejected() {
        XCTAssertFalse(XURLValidator.isXURL("https://notx.com/user/status/123"))
        XCTAssertFalse(XURLValidator.isXURL("https://fake-x.com/user/status/123"))
    }

    func testSuffixedHostIsRejected() {
        XCTAssertFalse(XURLValidator.isXURL("https://x.com.evil.com/user/status/123"))
    }

    func testUnknownSubdomainIsRejected() {
        XCTAssertFalse(XURLValidator.isXURL("https://api.x.com/user/status/123"))
    }

    func testPlainText() {
        XCTAssertFalse(XURLValidator.isXURL("not a url"))
    }

    func testFilePath() {
        XCTAssertFalse(XURLValidator.isXURL("/Users/test/video.mp4"))
    }

    func testTrailingTextAfterURLIsRejected() {
        XCTAssertFalse(XURLValidator.isXURL("https://x.com/user/status/123 hello"))
    }
}

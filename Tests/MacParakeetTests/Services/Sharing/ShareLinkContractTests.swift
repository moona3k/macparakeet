import XCTest
@testable import MacParakeetCore

final class ShareLinkContractTests: XCTestCase {
    // MARK: - Generation and grammar

    func testGeneratedLinkMatchesTheV1Grammar() {
        let link = ShareLink.generate()

        XCTAssertEqual(link.locator.rawValue.count, ShareLocator.encodedLength)
        XCTAssertEqual(link.contentKey.rawValue.count, ShareContentKey.encodedLength)
        XCTAssertEqual(
            link.url.absoluteString,
            "https://share.macparakeet.com/s/\(link.locator.rawValue)#v1.\(link.contentKey.rawValue)")
    }

    func testGeneratedLocatorsAndContentKeysAreNotRepeated() {
        let links = (0..<100).map { _ in ShareLink.generate() }
        XCTAssertEqual(Set(links.map(\.locator.rawValue)).count, links.count)
        XCTAssertEqual(Set(links.map { $0.contentKey.rawValue }).count, links.count)
    }

    // MARK: - Round trip

    func testRoundTripThroughAURLPreservesLocatorAndContentKey() throws {
        let link = ShareLink.generate()
        let parsed = try ShareLink(url: link.url)
        XCTAssertEqual(parsed, link)
    }

    // MARK: - Fragment never reaches request URLs

    func testRequestURLOmitsTheFragment() {
        let link = ShareLink.generate()
        XCTAssertNil(link.requestURL.fragment)
        XCTAssertFalse(link.requestURL.absoluteString.contains("#"))
        XCTAssertEqual(
            link.requestURL.absoluteString,
            "https://share.macparakeet.com/s/\(link.locator.rawValue)"
        )
    }

    // MARK: - Malformed links fail closed

    func testWrongSchemeIsRejected() {
        let link = ShareLink.generate()
        var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
        components.scheme = "http"
        XCTAssertThrowsError(try ShareLink(url: components.url!)) { error in
            XCTAssertEqual(error as? ShareLinkError, .invalidScheme)
        }
    }

    func testWrongHostIsRejected() {
        let link = ShareLink.generate()
        var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
        components.host = "evil.example.com"
        XCTAssertThrowsError(try ShareLink(url: components.url!)) { error in
            XCTAssertEqual(error as? ShareLinkError, .invalidHost)
        }
    }

    func testWrongPathIsRejected() {
        let link = ShareLink.generate()
        var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
        components.path = "/x/\(link.locator.rawValue)"
        XCTAssertThrowsError(try ShareLink(url: components.url!)) { error in
            XCTAssertEqual(error as? ShareLinkError, .invalidPath)
        }
    }

    func testMissingFragmentIsRejected() {
        let link = ShareLink.generate()
        var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
        components.fragment = nil
        XCTAssertThrowsError(try ShareLink(url: components.url!)) { error in
            XCTAssertEqual(error as? ShareLinkError, .missingFragment)
        }
    }

    func testUnsupportedFragmentVersionIsRejected() {
        let link = ShareLink.generate()
        var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
        components.fragment = "v2.\(link.contentKey.rawValue)"
        XCTAssertThrowsError(try ShareLink(url: components.url!)) { error in
            XCTAssertEqual(error as? ShareLinkError, .invalidFragmentVersion)
        }
    }

    func testMalformedLocatorLengthIsRejected() {
        XCTAssertThrowsError(try ShareLocator(rawValue: "tooshort")) { error in
            XCTAssertEqual(error as? ShareLinkError, .invalidLocatorEncoding)
        }
    }

    func testMalformedLocatorAlphabetIsRejected() {
        let link = ShareLink.generate()
        let invalid = String(link.locator.rawValue.dropLast()) + "!"
        XCTAssertThrowsError(try ShareLocator(rawValue: invalid)) { error in
            XCTAssertEqual(error as? ShareLinkError, .invalidLocatorEncoding)
        }
    }

    func testPaddedLocatorEncodingIsRejected() {
        // A syntactically padded value (trailing '=') is never produced by
        // this contract and must fail closed rather than silently decode.
        XCTAssertThrowsError(try ShareLocator(rawValue: "AAAAAAAAAAAAAAAAAAAAA=")) { error in
            XCTAssertEqual(error as? ShareLinkError, .invalidLocatorEncoding)
        }
    }

    func testMalformedContentKeyLengthIsRejected() {
        XCTAssertThrowsError(try ShareContentKey(rawValue: "tooshort")) { error in
            XCTAssertEqual(error as? ShareLinkError, .invalidContentKeyEncoding)
        }
    }

    func testNonCanonicalBase64URLIsRejected() {
        // One bit flip in the final, otherwise-unused bits of a correctly
        // sized locator round-trips to a different canonical string, so it
        // must be rejected rather than silently accepted.
        let nonCanonical = "AAAAAAAAAAAAAAAAAAAAAB"
        XCTAssertNil(ShareBase64URL.decode(nonCanonical))
        XCTAssertThrowsError(try ShareLocator(rawValue: nonCanonical))
    }
}

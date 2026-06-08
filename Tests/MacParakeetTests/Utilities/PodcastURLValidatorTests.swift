import XCTest
@testable import MacParakeetCore

final class PodcastURLValidatorTests: XCTestCase {

    // MARK: - Episode URLs

    func testEpisodeURLWithCountryAndSlug() {
        let url = "https://podcasts.apple.com/us/podcast/the-daily/id1200361736?i=1000654321987"
        XCTAssertTrue(PodcastURLValidator.isApplePodcastsURL(url))
        XCTAssertEqual(PodcastURLValidator.extractCollectionID(url), "1200361736")
        XCTAssertEqual(PodcastURLValidator.extractEpisodeID(url), "1000654321987")
    }

    func testEpisodeURLWithExtraQueryItems() {
        let url = "https://podcasts.apple.com/gb/podcast/show/id123?i=456&l=en&foo=bar"
        XCTAssertEqual(PodcastURLValidator.extractCollectionID(url), "123")
        XCTAssertEqual(PodcastURLValidator.extractEpisodeID(url), "456")
    }

    func testEpisodeURLWithoutWWWIsAccepted() {
        let url = "podcasts.apple.com/us/podcast/x/id999?i=111"
        XCTAssertTrue(PodcastURLValidator.isApplePodcastsURL(url))
        XCTAssertEqual(PodcastURLValidator.extractCollectionID(url), "999")
        XCTAssertEqual(PodcastURLValidator.extractEpisodeID(url), "111")
    }

    // MARK: - Show URLs (no episode id)

    func testShowURLHasCollectionButNoEpisode() {
        let url = "https://podcasts.apple.com/us/podcast/the-daily/id1200361736"
        XCTAssertTrue(PodcastURLValidator.isApplePodcastsURL(url))
        XCTAssertEqual(PodcastURLValidator.extractCollectionID(url), "1200361736")
        XCTAssertNil(PodcastURLValidator.extractEpisodeID(url))
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        let url = "   https://podcasts.apple.com/us/podcast/x/id42?i=7   "
        XCTAssertTrue(PodcastURLValidator.isApplePodcastsURL(url))
        XCTAssertEqual(PodcastURLValidator.extractCollectionID(url), "42")
        XCTAssertEqual(PodcastURLValidator.extractEpisodeID(url), "7")
    }

    // MARK: - Rejected inputs

    func testYouTubeURLIsNotApplePodcasts() {
        XCTAssertFalse(PodcastURLValidator.isApplePodcastsURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testGenericHostIsRejected() {
        XCTAssertFalse(PodcastURLValidator.isApplePodcastsURL("https://overcast.fm/+abc123"))
        XCTAssertFalse(PodcastURLValidator.isApplePodcastsURL("https://example.com/feed.mp3"))
    }

    func testApplePodcastsURLWithoutCollectionIDIsRejected() {
        // A bare host or a browse page carries no resolvable `id{digits}`.
        XCTAssertFalse(PodcastURLValidator.isApplePodcastsURL("https://podcasts.apple.com/us/browse"))
        XCTAssertNil(PodcastURLValidator.extractCollectionID("https://podcasts.apple.com"))
    }

    func testNonNumericEpisodeIDIsIgnored() {
        let url = "https://podcasts.apple.com/us/podcast/x/id42?i=not-a-number"
        XCTAssertEqual(PodcastURLValidator.extractCollectionID(url), "42")
        XCTAssertNil(PodcastURLValidator.extractEpisodeID(url))
    }

    func testEmptyAndWhitespaceInputsAreRejected() {
        XCTAssertFalse(PodcastURLValidator.isApplePodcastsURL(""))
        XCTAssertFalse(PodcastURLValidator.isApplePodcastsURL("   "))
        XCTAssertFalse(PodcastURLValidator.isApplePodcastsURL("https://podcasts.apple.com/us/podcast/x id42"))
    }
}

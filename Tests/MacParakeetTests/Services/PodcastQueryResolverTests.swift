import XCTest
@testable import MacParakeetCore

private struct StubDirectory: PodcastDirectorySearching {
    let shows: [PodcastShow]
    func searchShows(query: String, limit: Int) async throws -> [PodcastShow] { shows }
    func feedURL(forShowID showID: Int) async throws -> String {
        shows.first?.feedURL ?? ""
    }
}

final class PodcastQueryResolverTests: XCTestCase {

    private static let feed = """
    <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
     <item><title>Episode 705: Train Your AI Team</title><enclosure url="https://cdn/705.mp3" type="audio/mpeg"/><itunes:duration>2700</itunes:duration><pubDate>Mon, 01 Jul 2024 07:00:00 GMT</pubDate></item>
     <item><title>Episode 704: Data Strategy</title><enclosure url="https://cdn/704.mp3" type="audio/mpeg"/></item>
    </channel></rss>
    """

    private func resolver(feed: String = feed) -> PodcastQueryResolver {
        let directory = StubDirectory(shows: [
            PodcastShow(collectionName: "Everyday AI", feedURL: "https://feeds/eai.rss", collectionID: 1, artworkURL: "https://art/eai.jpg"),
        ])
        let data = Data(feed.utf8)
        return PodcastQueryResolver(directory: directory, feedFetcher: { _ in data })
    }

    func testResolvesFreetextToBestEpisode() async throws {
        let resolved = try await resolver().resolve(query: "Everyday AI episode 705 train your team")
        XCTAssertEqual(resolved.audioURL, "https://cdn/705.mp3")
        XCTAssertEqual(resolved.episodeTitle, "Episode 705: Train Your AI Team")
        XCTAssertEqual(resolved.showName, "Everyday AI")
        XCTAssertEqual(resolved.artworkURL, "https://art/eai.jpg")
        XCTAssertEqual(resolved.durationSeconds, 2700)
        XCTAssertEqual(resolved.releaseDate, "2024-07-01")
        XCTAssertEqual(resolved.feedURL, "https://feeds/eai.rss")
    }

    func testResolvesToLatestWhenNoHints() async throws {
        let resolved = try await resolver().resolve(query: "Everyday AI")
        XCTAssertEqual(resolved.audioURL, "https://cdn/705.mp3")
    }

    func testResolvesSpecificEpisodeByNumber() async throws {
        let resolved = try await resolver().resolve(query: "Everyday AI episode 704")
        XCTAssertEqual(resolved.audioURL, "https://cdn/704.mp3")
    }

    func testNoShowsThrows() async {
        let resolver = PodcastQueryResolver(
            directory: StubDirectory(shows: []),
            feedFetcher: { _ in Data() }
        )
        do {
            _ = try await resolver.resolve(query: "nothing")
            XCTFail("Expected noResults")
        } catch {
            XCTAssertEqual(error as? PodcastSearchError, .noResults)
        }
    }

    func testEmptyFeedThrowsNoEpisodes() async {
        let resolver = resolver(feed: "<rss><channel></channel></rss>")
        do {
            _ = try await resolver.resolve(query: "Everyday AI")
            XCTFail("Expected noEpisodes")
        } catch {
            XCTAssertEqual(error as? PodcastFeedError, .noEpisodes)
        }
    }

    func testNormalizedReleaseDateAcceptsRFC822Variants() {
        XCTAssertEqual(PodcastQueryResolver.normalizedReleaseDate("Mon, 01 Jul 2024 07:00:00 GMT"), "2024-07-01")
        XCTAssertEqual(PodcastQueryResolver.normalizedReleaseDate("Mon, 1 Jul 2024 07:00:00 +0000"), "2024-07-01", "single-digit day")
        XCTAssertEqual(PodcastQueryResolver.normalizedReleaseDate("1 Jul 2024 07:00:00 +0000"), "2024-07-01", "no weekday")
        XCTAssertEqual(PodcastQueryResolver.normalizedReleaseDate("Mon, 01 Jul 2024 07:00 GMT"), "2024-07-01", "no seconds")
        XCTAssertNil(PodcastQueryResolver.normalizedReleaseDate("not a date"))
        XCTAssertNil(PodcastQueryResolver.normalizedReleaseDate(nil))
    }
}

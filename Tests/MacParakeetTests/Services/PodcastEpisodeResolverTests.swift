import XCTest
@testable import MacParakeetCore

final class PodcastEpisodeResolverTests: XCTestCase {

    // MARK: - Episode lookup

    func testResolvesEpisodeURLToEnclosureAndMetadata() async throws {
        let json = """
        {
          "resultCount": 1,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "Episode 42: On Patience",
              "collectionName": "The Daily",
              "feedUrl": "https://feeds.example.com/thedaily.rss",
              "episodeUrl": "https://cdn.example.com/audio/42.mp3",
              "artworkUrl600": "https://art.example.com/600.jpg",
              "artworkUrl100": "https://art.example.com/100.jpg",
              "description": "A long-form episode description.",
              "releaseDate": "2024-06-01T07:00:00Z",
              "trackTimeMillis": 1830000
            }
          ]
        }
        """
        let resolver = PodcastEpisodeResolver(dataFetcher: Self.fixtureFetcher(json))

        let episode = try await resolver.resolve(
            url: "https://podcasts.apple.com/us/podcast/the-daily/id1200361736?i=1000654321987"
        )

        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/audio/42.mp3")
        XCTAssertEqual(episode.episodeTitle, "Episode 42: On Patience")
        XCTAssertEqual(episode.showName, "The Daily")
        XCTAssertEqual(episode.artworkURL, "https://art.example.com/600.jpg")
        XCTAssertEqual(episode.episodeDescription, "A long-form episode description.")
        XCTAssertEqual(episode.durationSeconds, 1830)
        XCTAssertEqual(episode.releaseDate, "2024-06-01")
        XCTAssertEqual(episode.feedURL, "https://feeds.example.com/thedaily.rss")
    }

    func testShowURLPicksFirstEpisodeWithEnclosure() async throws {
        // A show lookup returns the collection (no episodeUrl) followed by
        // episodes newest-first; the resolver takes the latest playable one.
        let json = """
        {
          "resultCount": 2,
          "results": [
            { "wrapperType": "track", "kind": "podcast", "collectionName": "The Show", "feedUrl": "https://feeds.example.com/show.rss" },
            { "wrapperType": "podcastEpisode", "trackName": "Latest", "collectionName": "The Show", "episodeUrl": "https://cdn.example.com/latest.mp3", "trackTimeMillis": 600000 }
          ]
        }
        """
        let resolver = PodcastEpisodeResolver(dataFetcher: Self.fixtureFetcher(json))

        let episode = try await resolver.resolve(url: "https://podcasts.apple.com/us/podcast/the-show/id555")

        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/latest.mp3")
        XCTAssertEqual(episode.episodeTitle, "Latest")
        XCTAssertEqual(episode.durationSeconds, 600)
    }

    // MARK: - Errors

    func testInvalidURLThrows() async {
        let resolver = PodcastEpisodeResolver(dataFetcher: Self.fixtureFetcher("{}"))
        await assertThrows(PodcastResolveError.invalidURL) {
            try await resolver.resolve(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        }
    }

    func testEmptyResultsThrowsEpisodeNotFound() async {
        let resolver = PodcastEpisodeResolver(
            dataFetcher: Self.fixtureFetcher(#"{ "resultCount": 0, "results": [] }"#)
        )
        await assertThrows(PodcastResolveError.episodeNotFound) {
            try await resolver.resolve(url: "https://podcasts.apple.com/us/podcast/x/id1?i=2")
        }
    }

    func testResultsWithoutEnclosureThrowsNoPlayableAudio() async {
        let json = #"{ "resultCount": 1, "results": [ { "wrapperType": "track", "kind": "podcast", "collectionName": "X" } ] }"#
        let resolver = PodcastEpisodeResolver(dataFetcher: Self.fixtureFetcher(json))
        await assertThrows(PodcastResolveError.noPlayableAudio) {
            try await resolver.resolve(url: "https://podcasts.apple.com/us/podcast/x/id1?i=2")
        }
    }

    func testFetchErrorIsSurfacedAsLookupFailed() async {
        let resolver = PodcastEpisodeResolver(dataFetcher: { _ in
            throw PodcastResolveError.lookupFailed("HTTP 503")
        })
        await assertThrows(PodcastResolveError.lookupFailed("HTTP 503")) {
            try await resolver.resolve(url: "https://podcasts.apple.com/us/podcast/x/id1?i=2")
        }
    }

    // MARK: - Lookup URL + helpers

    func testLookupURLUsesEpisodeIDWhenPresent() throws {
        let url = try PodcastEpisodeResolver.lookupURL(collectionID: "111", episodeID: "222")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["id"], "222")
        XCTAssertEqual(items["entity"], "podcastEpisode")
    }

    func testLookupURLUsesCollectionIDWhenNoEpisode() throws {
        let url = try PodcastEpisodeResolver.lookupURL(collectionID: "111", episodeID: nil)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["id"], "111")
    }

    func testNormalizedReleaseDateTrimsISOTimestamp() {
        XCTAssertEqual(PodcastEpisodeResolver.normalizedReleaseDate("2024-06-01T07:00:00Z"), "2024-06-01")
        XCTAssertEqual(PodcastEpisodeResolver.normalizedReleaseDate("2024-12-31"), "2024-12-31")
        XCTAssertNil(PodcastEpisodeResolver.normalizedReleaseDate("June 1, 2024"))
        XCTAssertNil(PodcastEpisodeResolver.normalizedReleaseDate(nil))
    }

    // MARK: - Helpers

    private static func fixtureFetcher(_ json: String) -> PodcastEpisodeResolver.DataFetcher {
        let data = Data(json.utf8)
        return { _ in data }
    }

    private func assertThrows(
        _ expected: PodcastResolveError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as PodcastResolveError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

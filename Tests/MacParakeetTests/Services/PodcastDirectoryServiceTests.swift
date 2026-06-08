import XCTest
@testable import MacParakeetCore

final class PodcastDirectoryServiceTests: XCTestCase {

    func testSearchDecodesShows() async throws {
        let json = """
        {"resultCount":2,"results":[
         {"collectionName":"Lex Fridman Podcast","feedUrl":"https://lexfridman.com/feed/podcast/","collectionId":1434243584,"artworkUrl600":"https://art/600.jpg"},
         {"collectionName":"Other","feedUrl":"https://other/feed.rss","collectionId":99,"artworkUrl100":"https://art/100.jpg"}
        ]}
        """
        let directory = PodcastDirectoryService(dataFetcher: Self.fetcher(json))
        let shows = try await directory.searchShows(query: "Lex Fridman")

        XCTAssertEqual(shows.count, 2)
        XCTAssertEqual(shows[0].collectionName, "Lex Fridman Podcast")
        XCTAssertEqual(shows[0].feedURL, "https://lexfridman.com/feed/podcast/")
        XCTAssertEqual(shows[0].collectionID, 1434243584)
        XCTAssertEqual(shows[0].artworkURL, "https://art/600.jpg")
        XCTAssertEqual(shows[1].artworkURL, "https://art/100.jpg", "falls back to artwork100")
    }

    func testEmptyQueryThrows() async {
        let directory = PodcastDirectoryService(dataFetcher: Self.fetcher("{}"))
        do {
            _ = try await directory.searchShows(query: "   ")
            XCTFail("Expected emptyQuery")
        } catch {
            XCTAssertEqual(error as? PodcastSearchError, .emptyQuery)
        }
    }

    func testFeedURLLookup() async throws {
        let json = #"{"resultCount":1,"results":[{"collectionName":"X","feedUrl":"https://feeds/x.rss","collectionId":1}]}"#
        let directory = PodcastDirectoryService(dataFetcher: Self.fetcher(json))
        let feed = try await directory.feedURL(forShowID: 1)
        XCTAssertEqual(feed, "https://feeds/x.rss")
    }

    func testFeedURLLookupNoResultsThrows() async {
        let directory = PodcastDirectoryService(dataFetcher: Self.fetcher(#"{"resultCount":0,"results":[]}"#))
        do {
            _ = try await directory.feedURL(forShowID: 1)
            XCTFail("Expected noResults")
        } catch {
            XCTAssertEqual(error as? PodcastSearchError, .noResults)
        }
    }

    func testSearchURLQueryItems() throws {
        let url = try PodcastDirectoryService.searchURL(term: "lex fridman", limit: 10)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["term"], "lex fridman")
        XCTAssertEqual(items["entity"], "podcast")
        XCTAssertEqual(items["limit"], "10")
    }

    private static func fetcher(_ json: String) -> PodcastDirectoryService.DataFetcher {
        let data = Data(json.utf8)
        return { _ in data }
    }
}

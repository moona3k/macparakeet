import XCTest
@testable import MacParakeetCore

// MARK: - Mock URL Protocol

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class DiscoverServiceTests: XCTestCase {
    var session: URLSession!
    var tmpDir: URL!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("discover-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private var cachePath: String {
        tmpDir.appendingPathComponent("discover-cache.json").path
    }

    private func makeFallbackData(version: Int = 1) -> Data {
        let json = """
        {"version":\(version),"featuredIndex":0,"items":[
            {"id":"fallback-1","type":"tip","title":"Fallback Tip","body":"Fallback body","icon":"star"}
        ]}
        """
        return Data(json.utf8)
    }

    private func makeService(fallbackData: Data? = nil) -> DiscoverService {
        DiscoverService(
            feedURL: URL(string: "https://test.example.com/discover.json")!,
            cachePath: cachePath,
            fallbackData: fallbackData ?? makeFallbackData(),
            session: session
        )
    }

    // MARK: - loadContent

    func testLoadContentReturnsFallbackWhenNoCacheExists() async {
        let service = makeService()
        let feed = await service.loadContent()

        XCTAssertEqual(feed.version, 1)
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertEqual(feed.items.first?.id, "fallback-1")
    }

    func testLoadContentReturnsCacheWhenAvailable() async throws {
        let cachedFeed = DiscoverFeed(
            version: 2,
            items: [
                DiscoverItem(id: "cached-1", type: .quote, title: "Cached", body: "From cache", icon: "quote.bubble")
            ]
        )
        let data = try JSONEncoder().encode(cachedFeed)
        try data.write(to: URL(fileURLWithPath: cachePath))

        let service = makeService()
        let feed = await service.loadContent()

        XCTAssertEqual(feed.version, 2)
        XCTAssertEqual(feed.items.first?.id, "cached-1")
    }

    func testLoadContentReturnsEmptyFeedWhenBothFail() async {
        let service = makeService(fallbackData: Data("invalid".utf8))
        let feed = await service.loadContent()

        XCTAssertEqual(feed.items.count, 0)
    }

    // MARK: - fetchFresh

    func testFetchFreshReturnsDecodedFeed() async {
        let remoteFeed = """
        {"version":3,"featuredIndex":0,"items":[
            {"id":"remote-1","type":"affirmation","title":"Remote","body":"From server","icon":"sparkles"}
        ]}
        """

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(remoteFeed.utf8))
        }

        let service = makeService()
        let feed = await service.fetchFresh()

        XCTAssertNotNil(feed)
        XCTAssertEqual(feed?.version, 3)
        XCTAssertEqual(feed?.items.first?.id, "remote-1")
    }

    func testFetchFreshWritesToCache() async {
        let remoteFeed = """
        {"version":4,"featuredIndex":0,"items":[
            {"id":"cached-write","type":"tip","title":"Written","body":"To cache","icon":"star"}
        ]}
        """

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(remoteFeed.utf8))
        }

        let service = makeService()
        _ = await service.fetchFresh()

        // Verify cache file was written
        let cacheData = FileManager.default.contents(atPath: cachePath)
        XCTAssertNotNil(cacheData)
        let cached = try? JSONDecoder().decode(DiscoverFeed.self, from: cacheData!)
        XCTAssertEqual(cached?.version, 4)
    }

    func testFetchFreshReturnsNilOnServerError() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let service = makeService()
        let feed = await service.fetchFresh()

        XCTAssertNil(feed)
    }

    func testFetchFreshReturnsNilOnInvalidJSON() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("not json".utf8))
        }

        let service = makeService()
        let feed = await service.fetchFresh()

        XCTAssertNil(feed)
    }

    func testFetchFreshReturnsNilOnNetworkFailure() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let service = makeService()
        let feed = await service.fetchFresh()

        XCTAssertNil(feed)
    }
}

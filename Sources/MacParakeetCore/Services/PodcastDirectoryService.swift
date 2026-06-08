import Foundation

/// A podcast show from the iTunes Search API. Swift port of `podcast-fetch`'s
/// `PodcastResult`.
public struct PodcastShow: Sendable, Equatable {
    public let collectionName: String?
    public let feedURL: String?
    public let collectionID: Int?
    public let artworkURL: String?

    public init(collectionName: String?, feedURL: String?, collectionID: Int?, artworkURL: String?) {
        self.collectionName = collectionName
        self.feedURL = feedURL
        self.collectionID = collectionID
        self.artworkURL = artworkURL
    }
}

public enum PodcastSearchError: Error, LocalizedError, Equatable {
    case emptyQuery
    case requestFailed(String)
    case decodeFailed
    case noResults

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: return "Enter something to search for"
        case .requestFailed(let reason): return "Podcast search failed: \(reason)"
        case .decodeFailed: return "Unexpected response from Apple Podcasts search"
        case .noResults: return "No podcasts matched that search"
        }
    }
}

public protocol PodcastDirectorySearching: Sendable {
    /// Search the iTunes podcast directory, returning up to `limit` shows.
    func searchShows(query: String, limit: Int) async throws -> [PodcastShow]
    /// Resolve a show's RSS feed URL by its iTunes collection id.
    func feedURL(forShowID showID: Int) async throws -> String
}

extension PodcastDirectorySearching {
    public func searchShows(query: String) async throws -> [PodcastShow] {
        try await searchShows(query: query, limit: 10)
    }
}

/// iTunes Search API client for podcast discovery. Swift port of
/// `podcast-fetch`'s `search` module (search + feed-url lookup). Dependency-free
/// (URLSession + an injectable fetcher for tests).
public actor PodcastDirectoryService: PodcastDirectorySearching {
    public typealias DataFetcher = @Sendable (URL) async throws -> Data

    private static let searchBase = "https://itunes.apple.com/search"
    private static let lookupBase = "https://itunes.apple.com/lookup"
    private let dataFetcher: DataFetcher

    public init(dataFetcher: DataFetcher? = nil) {
        self.dataFetcher = dataFetcher ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw PodcastSearchError.requestFailed("HTTP \(http.statusCode)")
            }
            return data
        }
    }

    public func searchShows(query: String, limit: Int = 10) async throws -> [PodcastShow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PodcastSearchError.emptyQuery }

        let url = try Self.searchURL(term: trimmed, limit: limit)
        let response = try await decodeLookup(from: url)
        return response.results.map(Self.show(from:))
    }

    public func feedURL(forShowID showID: Int) async throws -> String {
        let url = try Self.lookupURL(showID: showID)
        let response = try await decodeLookup(from: url)
        guard let feed = response.results.compactMap(\.feedUrl).first(where: { !$0.isEmpty }) else {
            throw PodcastSearchError.noResults
        }
        return feed
    }

    // MARK: - Private

    private func decodeLookup(from url: URL) async throws -> ItunesLookupResponse {
        let data: Data
        do {
            data = try await dataFetcher(url)
        } catch let error as PodcastSearchError {
            throw error
        } catch {
            throw PodcastSearchError.requestFailed(error.localizedDescription)
        }
        guard let response = try? JSONDecoder().decode(ItunesLookupResponse.self, from: data) else {
            throw PodcastSearchError.decodeFailed
        }
        return response
    }

    static func searchURL(term: String, limit: Int) throws -> URL {
        var components = URLComponents(string: searchBase)
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
        ]
        guard let url = components?.url else { throw PodcastSearchError.requestFailed("invalid URL") }
        return url
    }

    static func lookupURL(showID: Int) throws -> URL {
        var components = URLComponents(string: lookupBase)
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(showID)),
            URLQueryItem(name: "entity", value: "podcast"),
        ]
        guard let url = components?.url else { throw PodcastSearchError.requestFailed("invalid URL") }
        return url
    }

    static func show(from result: ItunesResult) -> PodcastShow {
        PodcastShow(
            collectionName: result.collectionName,
            feedURL: result.feedUrl,
            collectionID: result.collectionId,
            artworkURL: result.artworkUrl600 ?? result.artworkUrl100
        )
    }
}

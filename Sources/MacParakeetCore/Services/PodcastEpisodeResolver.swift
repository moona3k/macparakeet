import Foundation
import os

public enum PodcastResolveError: Error, LocalizedError, Equatable {
    case invalidURL
    case lookupFailed(String)
    case episodeNotFound
    case noPlayableAudio

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Not a valid Apple Podcasts link"
        case .lookupFailed(let reason):
            return "Could not look up the podcast: \(reason)"
        case .episodeNotFound:
            return "That podcast episode could not be found on Apple Podcasts"
        case .noPlayableAudio:
            return "No downloadable audio is published for that episode"
        }
    }
}

/// A resolved podcast episode: a direct audio enclosure URL plus the rich
/// metadata an Apple Podcasts page never exposes inline. Mirrors the
/// `DownloadResult` shape `YouTubeDownloader` returns so the transcription
/// service can persist either with the same fields.
public struct ResolvedPodcastEpisode: Sendable, Equatable {
    public let audioURL: String
    public let episodeTitle: String
    public let showName: String?
    public let artworkURL: String?
    public let episodeDescription: String?
    public let durationSeconds: Int?
    /// `YYYY-MM-DD`, derived from the iTunes ISO-8601 release date.
    public let releaseDate: String?
    public let feedURL: String?

    public init(
        audioURL: String,
        episodeTitle: String,
        showName: String? = nil,
        artworkURL: String? = nil,
        episodeDescription: String? = nil,
        durationSeconds: Int? = nil,
        releaseDate: String? = nil,
        feedURL: String? = nil
    ) {
        self.audioURL = audioURL
        self.episodeTitle = episodeTitle
        self.showName = showName
        self.artworkURL = artworkURL
        self.episodeDescription = episodeDescription
        self.durationSeconds = durationSeconds
        self.releaseDate = releaseDate
        self.feedURL = feedURL
    }
}

public protocol PodcastResolving: Sendable {
    /// Resolve an Apple Podcasts URL to a playable episode. For an episode URL
    /// (`?i=`) this returns that episode; for a show URL it returns the latest
    /// published episode.
    func resolve(url: String) async throws -> ResolvedPodcastEpisode
}

/// Resolves Apple Podcasts links to a downloadable enclosure + metadata using
/// the public iTunes Lookup API — the same discovery path the standalone
/// `podcast-transcribe` tool uses, ported to Swift with no third-party deps.
///
/// The lookup returns the episode's `episodeUrl` (the RSS `<enclosure>` URL)
/// directly, so no XML feed parsing is needed for the common episode/show
/// cases. The audio is then fetched through the existing media-download path.
public actor PodcastEpisodeResolver: PodcastResolving {
    public typealias DataFetcher = @Sendable (URL) async throws -> Data

    private static let lookupBase = "https://itunes.apple.com/lookup"
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "PodcastEpisodeResolver")
    private let dataFetcher: DataFetcher

    public init(dataFetcher: DataFetcher? = nil) {
        self.dataFetcher = dataFetcher ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw PodcastResolveError.lookupFailed("HTTP \(http.statusCode)")
            }
            return data
        }
    }

    public func resolve(url: String) async throws -> ResolvedPodcastEpisode {
        guard let collectionID = PodcastURLValidator.extractCollectionID(url) else {
            throw PodcastResolveError.invalidURL
        }
        let episodeID = PodcastURLValidator.extractEpisodeID(url)
        let lookupURL = try Self.lookupURL(collectionID: collectionID, episodeID: episodeID)

        let data: Data
        do {
            data = try await dataFetcher(lookupURL)
        } catch let error as PodcastResolveError {
            throw error
        } catch {
            throw PodcastResolveError.lookupFailed(error.localizedDescription)
        }

        let response: ItunesLookupResponse
        do {
            response = try JSONDecoder().decode(ItunesLookupResponse.self, from: data)
        } catch {
            throw PodcastResolveError.lookupFailed("Unexpected response from Apple Podcasts")
        }

        guard !response.results.isEmpty else {
            throw PodcastResolveError.episodeNotFound
        }

        // The lookup returns the show collection plus episodes (newest first).
        // The first result carrying an `episodeUrl` is the requested episode for
        // an episode lookup, or the latest episode for a show lookup.
        guard let episode = response.results.first(where: { ($0.episodeUrl?.isEmpty == false) }) else {
            throw PodcastResolveError.noPlayableAudio
        }
        guard let audioURL = episode.episodeUrl, !audioURL.isEmpty else {
            throw PodcastResolveError.noPlayableAudio
        }

        let feed = response.results.compactMap(\.feedUrl).first

        return ResolvedPodcastEpisode(
            audioURL: audioURL,
            // Don't fall back to the show name — a missing track name should read
            // as a clear placeholder, not silently mislabel the episode as the show.
            episodeTitle: Self.firstNonEmpty(episode.trackName) ?? "Podcast episode",
            showName: Self.firstNonEmpty(episode.collectionName),
            artworkURL: Self.firstNonEmpty(episode.artworkUrl600, episode.artworkUrl160, episode.artworkUrl100),
            episodeDescription: Self.firstNonEmpty(episode.description, episode.shortDescription),
            durationSeconds: episode.trackTimeMillis.flatMap { $0 > 0 ? $0 / 1000 : nil },
            releaseDate: Self.normalizedReleaseDate(episode.releaseDate),
            feedURL: Self.firstNonEmpty(feed)
        )
    }

    // MARK: - Lookup URL

    static func lookupURL(collectionID: String, episodeID: String?) throws -> URL {
        var components = URLComponents(string: lookupBase)
        var items = [URLQueryItem(name: "entity", value: "podcastEpisode")]
        if let episodeID {
            // Looking up the episode's own track id returns just that episode.
            items.insert(URLQueryItem(name: "id", value: episodeID), at: 0)
        } else {
            // Looking up the show id returns the show plus its recent episodes,
            // newest first — we only need the collection header + the latest
            // episode, so cap the response (the API defaults to 200 otherwise).
            items.insert(URLQueryItem(name: "id", value: collectionID), at: 0)
            items.append(URLQueryItem(name: "limit", value: "2"))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw PodcastResolveError.invalidURL
        }
        return url
    }

    // MARK: - Helpers

    /// Convert an iTunes ISO-8601 timestamp (`2024-06-01T07:00:00Z`) to the
    /// `YYYY-MM-DD` form the downloader uses for readable file naming.
    static func normalizedReleaseDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else {
            return nil
        }
        // `raw.count >= 10` is guaranteed above, so `prefix(10)` is exactly 10 chars.
        let datePart = String(raw.prefix(10))
        let isYYYYMMDD = datePart[datePart.index(datePart.startIndex, offsetBy: 4)] == "-"
            && datePart[datePart.index(datePart.startIndex, offsetBy: 7)] == "-"
        return isYYYYMMDD ? datePart : nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

// MARK: - iTunes Lookup decoding

struct ItunesLookupResponse: Decodable {
    let resultCount: Int
    let results: [ItunesResult]
}

struct ItunesResult: Decodable {
    let wrapperType: String?
    let kind: String?
    let trackName: String?
    let collectionName: String?
    let collectionId: Int?
    let feedUrl: String?
    let episodeUrl: String?
    let artworkUrl600: String?
    let artworkUrl160: String?
    let artworkUrl100: String?
    let description: String?
    let shortDescription: String?
    let releaseDate: String?
    let trackTimeMillis: Int?
}

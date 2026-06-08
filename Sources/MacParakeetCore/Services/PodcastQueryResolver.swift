import Foundation

public protocol PodcastSearchResolving: Sendable {
    /// Resolve a freetext query (e.g. `"Lex Fridman episode 400"`) to a playable
    /// episode by searching the iTunes directory, parsing the show's RSS feed,
    /// and selecting the best-matching episode (or the latest).
    func resolve(query: String) async throws -> ResolvedPodcastEpisode
}

/// Ties the ported `podcast-fetch` pieces together: freetext parsing →
/// iTunes search → RSS feed parse → episode selection → a `ResolvedPodcastEpisode`
/// the transcription service can fetch and transcribe. Mirrors the
/// `transcribe_from_freetext` flow in the `podcast-transcribe` CLI.
public actor PodcastQueryResolver: PodcastSearchResolving {
    public typealias FeedFetcher = @Sendable (URL) async throws -> Data

    private let directory: PodcastDirectorySearching
    private let feedFetcher: FeedFetcher

    public init(
        directory: PodcastDirectorySearching = PodcastDirectoryService(),
        feedFetcher: FeedFetcher? = nil
    ) {
        self.directory = directory
        self.feedFetcher = feedFetcher ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw PodcastFeedError.parseFailed("HTTP \(http.statusCode)")
            }
            return data
        }
    }

    public func resolve(query: String) async throws -> ResolvedPodcastEpisode {
        let (showQuery, hints) = PodcastEpisodeMatcher.parseFreetextQuery(query)
        let effectiveShowQuery = showQuery.isEmpty ? query : showQuery

        let shows = try await directory.searchShows(query: effectiveShowQuery)
        guard let show = shows.first(where: { ($0.feedURL?.isEmpty == false) }),
              let feedURLString = show.feedURL,
              let feedURL = URL(string: feedURLString)
        else {
            throw PodcastSearchError.noResults
        }

        let feedData = try await feedFetcher(feedURL)
        let episodes = try PodcastFeedParser.parse(feedData)
        guard let episode = PodcastEpisodeMatcher.selectEpisode(episodes, hints: hints) else {
            throw PodcastFeedError.noEpisodes
        }

        return ResolvedPodcastEpisode(
            audioURL: episode.audioURL,
            episodeTitle: episode.title,
            showName: show.collectionName,
            artworkURL: show.artworkURL,
            episodeDescription: episode.description,
            durationSeconds: episode.durationSeconds,
            releaseDate: Self.normalizedReleaseDate(episode.published),
            feedURL: feedURLString
        )
    }

    /// Convert an RSS RFC-822 `pubDate` to `YYYY-MM-DD`, or nil if unparseable.
    static func normalizedReleaseDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let inFormatter = DateFormatter()
        inFormatter.locale = Locale(identifier: "en_US_POSIX")
        inFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        guard let date = inFormatter.date(from: raw) else { return nil }
        let outFormatter = DateFormatter()
        outFormatter.locale = Locale(identifier: "en_US_POSIX")
        outFormatter.timeZone = TimeZone(identifier: "UTC")
        outFormatter.dateFormat = "yyyy-MM-dd"
        return outFormatter.string(from: date)
    }
}

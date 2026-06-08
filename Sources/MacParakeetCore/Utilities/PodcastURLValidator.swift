import Foundation

/// Recognizes Apple Podcasts share URLs and extracts the collection (show) and
/// episode identifiers needed to resolve a playable enclosure via the iTunes
/// Lookup API.
///
/// This is the podcast analogue of `YouTubeURLValidator`. It intentionally only
/// claims `podcasts.apple.com` links — a raw RSS feed or a direct audio URL is
/// already handled by the generic `DownloadableMediaURLValidator` path, so the
/// only gap a podcast surface has to fill is the Apple Podcasts page URL, whose
/// HTML never points straight at audio.
///
/// Apple Podcasts URLs take the shape:
///   https://podcasts.apple.com/us/podcast/{slug}/id{collectionID}?i={episodeID}
/// The trailing `?i=` is present for a single episode and absent for a show
/// (where we resolve the latest episode).
public enum PodcastURLValidator {
    private static let podcastHosts: Set<String> = [
        "podcasts.apple.com",
        "podcast.apple.com",
    ]

    /// `true` when the string is an Apple Podcasts URL we can resolve (i.e. a
    /// recognized host carrying an `id{digits}` collection identifier).
    public static func isApplePodcastsURL(_ string: String) -> Bool {
        extractCollectionID(string) != nil
    }

    /// Extract the numeric collection (show) identifier from the `id{digits}`
    /// path segment, or `nil` when the URL is not a recognized Apple Podcasts URL.
    public static func extractCollectionID(_ string: String) -> String? {
        guard let components = normalizedComponents(string) else { return nil }
        for rawSegment in components.path.split(separator: "/") {
            let segment = rawSegment.lowercased()
            guard segment.hasPrefix("id") else { continue }
            let digits = segment.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                return String(digits)
            }
        }
        return nil
    }

    /// Extract the numeric episode identifier from the `i=` query item, or `nil`
    /// for a show URL that does not name a specific episode.
    public static func extractEpisodeID(_ string: String) -> String? {
        guard let components = normalizedComponents(string) else { return nil }
        let value = components.queryItems?.first(where: { $0.name == "i" })?.value
        guard let value, !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    // MARK: - Private

    private static func normalizedComponents(_ string: String) -> URLComponents? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        let normalizedInput = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalizedInput),
              let host = components.host?.lowercased(),
              podcastHosts.contains(host)
        else {
            return nil
        }
        return components
    }
}

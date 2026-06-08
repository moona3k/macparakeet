import Foundation

/// Validates X (formerly Twitter) status URLs that may contain downloadable video.
///
/// Intentionally scoped to the `/{user}/status/{id}` (and `/i/status/{id}`) form,
/// which is what `yt-dlp` extracts video from — profile/timeline URLs have no
/// single video to download. Callers that also accept YouTube should check
/// ``YouTubeURLValidator`` first (for videoID-based dedup/telemetry), then fall
/// back to this check. The downloader's generic ``DownloadableMediaURLValidator``
/// already accepts these URLs; this stricter validator drives the front-end
/// "YouTube or X" button-enable gate so the UI only lights up for real X videos.
public enum XURLValidator {
    private static let xHosts: Set<String> = [
        "x.com",
        "www.x.com",
        "mobile.x.com",
        "twitter.com",
        "www.twitter.com",
        "mobile.twitter.com",
    ]

    /// Check if a string is an X/Twitter status URL (a tweet that may contain video).
    public static func isXURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }

        let normalizedInput = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalizedInput),
              let host = components.host?.lowercased(),
              xHosts.contains(host)
        else {
            return false
        }

        // Require a `status` path segment followed by a numeric tweet id,
        // e.g. /{user}/status/{id} or /i/status/{id}.
        let segments = components.path.split(separator: "/").map(String.init)
        guard let statusIndex = segments.firstIndex(where: { $0.lowercased() == "status" }),
              statusIndex + 1 < segments.count
        else {
            return false
        }

        let tweetID = segments[statusIndex + 1]
        guard !tweetID.isEmpty, tweetID.allSatisfy(\.isNumber) else { return false }
        return true
    }
}

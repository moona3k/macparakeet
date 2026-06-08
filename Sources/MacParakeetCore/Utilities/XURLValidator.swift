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

        // Require a `status` path segment immediately followed by a numeric tweet
        // id, e.g. /{user}/status/{id} or /i/status/{id}. Scan ALL segments (not
        // just the first "status") so a username literally named "status"
        // (https://x.com/status/status/123) still validates. Tweet ids are always
        // ASCII digits, so reject the Unicode numerics that Character.isNumber
        // would otherwise accept (e.g. Arabic-Indic ٠١٢٣).
        let segments = components.path.split(separator: "/").map(String.init)
        return segments.indices.contains { index in
            segments[index].lowercased() == "status"
                && index + 1 < segments.count
                && !segments[index + 1].isEmpty
                && segments[index + 1].allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}

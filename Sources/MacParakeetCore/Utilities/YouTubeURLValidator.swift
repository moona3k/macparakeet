import Foundation

public enum YouTubeURLValidator {
    /// Matches YouTube video IDs: 11 chars of alphanumeric, dash, underscore
    private static let videoIDPattern = "[A-Za-z0-9_-]{11}"

    /// All recognized YouTube URL patterns
    private static let patterns: [(regex: String, idGroup: Int)] = [
        // youtube.com/watch?v=ID (with optional www., m.)
        (#"(?:https?://)?(?:www\.|m\.)?youtube\.com/watch\?.*v=("# + videoIDPattern + ")", 1),
        // youtu.be/ID
        (#"(?:https?://)?youtu\.be/("# + videoIDPattern + ")", 1),
        // youtube.com/shorts/ID
        (#"(?:https?://)?(?:www\.|m\.)?youtube\.com/shorts/("# + videoIDPattern + ")", 1),
        // youtube.com/embed/ID
        (#"(?:https?://)?(?:www\.|m\.)?youtube\.com/embed/("# + videoIDPattern + ")", 1),
        // youtube.com/v/ID
        (#"(?:https?://)?(?:www\.|m\.)?youtube\.com/v/("# + videoIDPattern + ")", 1),
    ]

    /// Check if a string is a valid YouTube URL
    public static func isYouTubeURL(_ string: String) -> Bool {
        extractVideoID(string) != nil
    }

    /// Extract the video ID from a YouTube URL, or nil if not a valid YouTube URL
    public static func extractVideoID(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for (pattern, group) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: trimmed,
                      range: NSRange(trimmed.startIndex..., in: trimmed)
                  ),
                  let idRange = Range(match.range(at: group), in: trimmed)
            else { continue }
            return String(trimmed[idRange])
        }

        return nil
    }
}

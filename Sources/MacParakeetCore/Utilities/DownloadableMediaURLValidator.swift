import Foundation

public enum DownloadableMediaURLValidator {
    /// This intentionally overlaps with YouTube URLs. Callers that need to
    /// distinguish YouTube telemetry/routing should check `YouTubeURLValidator`
    /// first, then fall back to this generic HTTP(S) media URL check.
    public static func isDownloadableMediaURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }

        let lowercased = trimmed.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else { return false }
        guard let separatorRange = trimmed.range(of: "://") else { return false }

        let afterScheme = trimmed[separatorRange.upperBound...]
        guard !afterScheme.isEmpty && !afterScheme.hasPrefix("/") else { return false }

        let hostEnd = afterScheme.firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? afterScheme.endIndex
        guard !afterScheme[..<hostEnd].isEmpty else { return false }

        return true
    }
}

import Foundation

/// Parses progress percentage from warm-up status messages.
/// Shared between STTClient (Core) and OnboardingViewModel (ViewModels).
public enum OnboardingProgressParser {
    private static let progressPercentRegex = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*%"#)

    /// Extract a 0.0–1.0 fraction from messages like "Downloading speech model... 45% (3/7)"
    public static func parseProgressFraction(from message: String) -> Double? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = progressPercentRegex.firstMatch(in: message, options: [], range: range),
              match.numberOfRanges >= 2,
              let numberRange = Range(match.range(at: 1), in: message),
              let percent = Double(message[numberRange]),
              percent >= 0,
              percent <= 100 else {
            return nil
        }
        return percent / 100
    }
}

import Foundation
import OSLog

struct MeetingTitleGenerator: Sendable {
    private static let minimumTranscriptWords = 12
    private static let maximumPromptTranscriptCharacters = 24_000
    private static let minimumTitleWords = 2
    private static let maximumTitleWords = 8
    private static let maximumTitleCharacters = 70

    private static let systemPrompt = """
    Generate a concise title for this meeting transcript.

    Rules:
    - Return only the title. Do not include quotes, markdown, JSON, or explanation.
    - Use 2 to 8 words.
    - Name the concrete topic of the meeting.
    - Do not use generic titles like "Meeting", "Discussion", "Transcript", or a date/time.
    - If the transcript does not have enough context for a useful topic title, return NO_TITLE.
    """

    let llmService: LLMServiceProtocol?
    let shouldGenerate: @Sendable () -> Bool
    let logger: Logger

    func generateTitle(transcript: String, currentTitle: String) async throws -> String? {
        guard shouldGenerate(), let llmService else { return nil }
        guard Self.shouldReplaceFallbackMeetingTitle(currentTitle) else { return nil }

        let normalizedTranscript = Self.normalizedWhitespace(transcript)
        guard Self.hasEnoughContext(normalizedTranscript) else { return nil }

        do {
            let rawTitle = try await llmService.generatePromptResult(
                transcript: Self.truncatedForPrompt(normalizedTranscript),
                systemPrompt: Self.systemPrompt
            )
            guard let title = Self.validatedTitle(from: rawTitle) else {
                logger.info("meeting_title_generation_rejected reason=invalid_response")
                return nil
            }
            return title
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("meeting_title_generation_failed error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public)")
            return nil
        }
    }

    static func shouldReplaceFallbackMeetingTitle(_ title: String) -> Bool {
        let normalized = normalizedWhitespace(title)
        guard normalized.localizedCaseInsensitiveCompare("Meeting") != .orderedSame else {
            return true
        }
        guard normalized.lowercased().hasPrefix("meeting ") else { return false }

        // The generated fallback ("Meeting Jun 17, 2026 at 09:59") always carries a
        // month name AND a clock time, so we match on those (plus slash dates) and
        // deliberately omit a bare-year pattern: a real calendar/custom title like
        // "Meeting 2026 Budget Planning" must not be treated as a fallback and
        // silently overwritten.
        let fallbackDatePattern = #"(?i)\b(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b"#
        return normalized.range(of: fallbackDatePattern, options: .regularExpression) != nil
    }

    static func validatedTitle(from rawTitle: String) -> String? {
        let lines = rawTitle
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1 else { return nil }

        var title = lines[0]
            .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+[\.)]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = stripWrappingQuotes(from: title)
        title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:;!?")))
        title = normalizedWhitespace(title)

        guard !title.isEmpty else { return nil }
        guard title.count <= maximumTitleCharacters else { return nil }

        let words = title.split(whereSeparator: \.isWhitespace)
        guard words.count >= minimumTitleWords, words.count <= maximumTitleWords else {
            return nil
        }

        let lowercased = title.lowercased()
        let genericTitles: Set<String> = [
            "meeting",
            "meeting notes",
            "meeting discussion",
            "discussion",
            "transcript",
            "transcription",
            "summary",
            "conversation",
            "call",
            "audio transcript",
            "no_title",
            "no title",
            "not enough context",
        ]
        guard !genericTitles.contains(lowercased) else { return nil }
        guard !lowercased.contains("not enough context") else { return nil }

        let dateLikePattern = #"(?i)\b20\d{2}\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b"#
        guard title.range(of: dateLikePattern, options: .regularExpression) == nil else {
            return nil
        }

        return title
    }

    private static func hasEnoughContext(_ transcript: String) -> Bool {
        transcript.split(whereSeparator: \.isWhitespace).count >= minimumTranscriptWords
    }

    private static func truncatedForPrompt(_ transcript: String) -> String {
        guard transcript.count > maximumPromptTranscriptCharacters else { return transcript }
        let half = maximumPromptTranscriptCharacters / 2
        return "\(transcript.prefix(half))\n\n[...]\n\n\(transcript.suffix(half))"
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func stripWrappingQuotes(from text: String) -> String {
        var result = text
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("‘", "’"),
        ]
        var changed = true
        while changed {
            changed = false
            for (open, close) in quotePairs where result.first == open && result.last == close && result.count >= 2 {
                result.removeFirst()
                result.removeLast()
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return result
    }
}

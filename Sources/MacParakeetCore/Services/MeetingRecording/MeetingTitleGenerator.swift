import Foundation
import OSLog

struct MeetingTitleGenerator: Sendable {
    private static let minimumTranscriptWords = 12
    private static let maximumPromptTranscriptCharacters = 24_000
    private static let minimumTitleWords = 2
    private static let maximumTitleCharacters = 70

    private static let systemPrompt = """
        Generate a concise title for this meeting transcript.

        Rules:
        - Return only the title. Do not include quotes, markdown, JSON, or explanation.
        - Aim for 2 to 8 words and stay within 70 characters.
        - Name the concrete topic of the meeting. Keep years when they are part of the topic.
        - Do not use generic titles like "Meeting", "Discussion", "Transcript", or a date/time.
        - If the transcript does not have enough context for a useful topic title, return NO_TITLE.
        """

    enum RejectionReason: String, Error {
        case empty
        case multiline
        case tooLong = "too_long"
        case tooFewWords = "too_few_words"
        case generic
        case dateTime = "date_time"
    }

    let llmService: LLMServiceProtocol?
    let shouldGenerate: @Sendable () -> Bool
    let logger: Logger

    func generateTitle(transcript: String, currentTitle: String) async throws -> String? {
        guard shouldGenerate(), let llmService else { return nil }
        guard Self.shouldReplaceFallbackMeetingTitle(currentTitle) else { return nil }

        let normalizedTranscript = Self.normalizedWhitespace(transcript)
        guard Self.hasEnoughContext(normalizedTranscript) else { return nil }

        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard shouldGenerate() else { return nil }
            do {
                let rawTitle = try await llmService.generatePromptResult(
                    transcript: Self.truncatedForPrompt(normalizedTranscript),
                    systemPrompt: Self.systemPrompt
                )
                try Task.checkCancellation()
                guard shouldGenerate() else { return nil }
                return try Self.validatedTitle(from: rawTitle)
            } catch let reason as RejectionReason {
                logger.notice("meeting_title_generation_rejected reason=\(reason.rawValue, privacy: .public)")
                return nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard shouldGenerate() else { return nil }
                guard attempt == 0, Self.shouldRetry(error) else {
                    logger.warning(
                        "meeting_title_generation_failed error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public)"
                    )
                    return nil
                }
                logger.notice(
                    "meeting_title_generation_retry error_type=\(TelemetryErrorClassifier.classify(error), privacy: .public)"
                )
                try await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        guard let error = error as? LLMError else { return false }
        switch error {
        case .connectionFailed, .requestTimedOut, .cliError:
            // CLI failures wrap unstructured stderr, including transient DNS errors.
            // Retry once without inspecting or logging potentially private content.
            return true
        default:
            return false
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
        let fallbackDatePattern =
            #"(?i)\b(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b"#
        return normalized.range(of: fallbackDatePattern, options: .regularExpression) != nil
    }

    static func validatedTitle(from rawTitle: String) throws -> String {
        let lines =
            rawTitle
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw RejectionReason.empty }
        guard lines.count == 1 else { throw RejectionReason.multiline }

        var title = lines[0]
            .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+[\.)]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = stripWrappingQuotes(from: title)
        title = title.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:;!?")))
        title = normalizedWhitespace(title)

        guard !title.isEmpty else { throw RejectionReason.empty }
        guard title.count <= maximumTitleCharacters else { throw RejectionReason.tooLong }

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
        guard !genericTitles.contains(lowercased), !lowercased.contains("not enough context") else {
            throw RejectionReason.generic
        }
        guard title.split(whereSeparator: \.isWhitespace).count >= minimumTitleWords else {
            throw RejectionReason.tooFewWords
        }

        // Years can name the topic. Reject actual dates/times, not budget years
        // or month names used as topics (for example, "May Hiring Plan").
        let month =
            "(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
        let dateLikePattern =
            #"(?i)\b\d{1,2}:\d{2}\b|\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|\b\d{1,2}\.\d{1,2}\.\d{4}\b|\b\d{4}[/-]\d{1,2}[/-]\d{1,2}\b|\b\#(month)\.?\s+\d{1,4}(?:st|nd|rd|th)?\b|\b\d{1,2}(?:st|nd|rd|th)?\s+\#(month)\b"#
        guard title.range(of: dateLikePattern, options: .regularExpression) == nil else {
            throw RejectionReason.dateTime
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

import Foundation

public enum AIFormatter {
    public static let transcriptPlaceholder = "{{TRANSCRIPT}}"
    static let legacyDefaultPromptTemplateV1 = """
        You are a transcription cleanup assistant.

        Convert the following raw transcript into polished, readable text.

        Instructions:
        1. Add punctuation and capitalization.
        2. Split the text into proper sentences and paragraphs.
        3. Fix obvious speech-to-text errors.
        4. Remove repeated words and filler sounds when unnecessary.
        5. Keep the original meaning, tone, and wording as close as possible.
        6. Do not summarize, shorten, or add content.
        7. Do not explain your edits.
        8. Output only the final cleaned text.

        Raw transcript:
        {{TRANSCRIPT}}
        """

    public static let defaultPromptTemplate = """
        You are a transcription cleanup assistant.

        Convert the following raw transcript into polished, readable text.

        Instructions:
        1. Add punctuation and capitalization.
        2. Split the text into natural sentences.
        3. Break the text into readable paragraphs whenever the speaker moves into a new topic, example, action taken, or result.
        4. Prefer short paragraphs of 1 to 3 sentences.
        5. For medium-length monologues, favor multiple paragraphs over one dense block when the ideas naturally separate.
        6. Use real paragraph breaks in the cleaned text. If you need a new paragraph, put it in the text itself instead of writing the characters \\n.
        7. Fix obvious speech-to-text errors.
        8. Remove repeated words and filler sounds when unnecessary.
        9. Keep the original meaning, tone, and wording as close as possible.
        10. Do not summarize, shorten, or add content.
        11. Do not explain your edits.
        12. Output only the final cleaned text.

        Raw transcript:
        {{TRANSCRIPT}}
        """

    public static func normalizedPromptTemplate(_ promptTemplate: String) -> String {
        let trimmed = promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultPromptTemplate }
        if trimmed == legacyDefaultPromptTemplateV1 {
            return defaultPromptTemplate
        }
        return trimmed
    }

    public static func renderPrompt(template promptTemplate: String, transcript: String) -> String {
        let normalizedTemplate = normalizedPromptTemplate(promptTemplate)
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedTemplate.contains(transcriptPlaceholder) else {
            guard !normalizedTranscript.isEmpty else { return normalizedTemplate }
            return normalizedTemplate + "\n\nRaw transcript:\n" + normalizedTranscript
        }

        return normalizedTemplate.replacingOccurrences(
            of: transcriptPlaceholder,
            with: normalizedTranscript
        )
    }

    public static func normalizedFormattedOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var normalized = trimmed.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\\r\\n", with: "\\n")

        if normalized.contains("\\n\\n") {
            normalized = normalized.replacingOccurrences(of: "\\n\\n", with: "\n\n")
        }

        if normalized.contains("\\n") {
            let replacement = normalized.contains("\n") ? "\n" : "\n\n"
            normalized = normalized.replacingOccurrences(of: "\\n", with: replacement)
        }

        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return normalized
    }
}

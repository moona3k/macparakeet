import Foundation

public enum PromptSystemPromptAssembler {
    public static let userNotesPromptWordCap = 8_000

    public static func assemble(
        promptContent: String,
        extraInstructions: String?,
        userNotes: String? = nil,
        transcript: String? = nil
    ) -> String {
        let cappedNotes = userNotes.map { truncateNotesForPrompt($0) }
        let renderedPrompt = PromptTemplateRenderer.render(
            promptContent,
            substitutions: [
                .userNotes: cappedNotes ?? "",
                .transcript: transcript ?? "",
            ]
        )

        let trimmedInstructions = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedInstructions, !trimmedInstructions.isEmpty else {
            return renderedPrompt
        }
        return renderedPrompt + "\n\n" + trimmedInstructions
    }

    /// Truncate meeting notes for prompt assembly without mutating the saved notes.
    public static func truncateNotesForPrompt(_ notes: String) -> String {
        let truncationIndex = indexAfterNthWord(in: notes, n: userNotesPromptWordCap)
        guard let truncationIndex else { return notes }
        let kept = notes[..<truncationIndex]
        return String(kept) + "\n\n[Notes truncated to \(userNotesPromptWordCap) words for summary generation; full notes preserved on the recording.]"
    }

    private static func indexAfterNthWord(in text: String, n: Int) -> String.Index? {
        guard n > 0 else { return text.startIndex }
        var wordCount = 0
        var inWord = false
        var nthWordEndIndex: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char.isWhitespace {
                inWord = false
            } else {
                if !inWord {
                    wordCount += 1
                    inWord = true
                    if wordCount == n + 1 {
                        return nthWordEndIndex
                    }
                }
                if wordCount == n {
                    nthWordEndIndex = text.index(after: index)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

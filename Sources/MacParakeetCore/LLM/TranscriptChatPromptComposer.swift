import Foundation

public struct TranscriptChatPromptPayload: Sendable {
    public let prompt: String
    public let defaultSystemPrompt: String

    public init(prompt: String, defaultSystemPrompt: String) {
        self.prompt = prompt
        self.defaultSystemPrompt = defaultSystemPrompt
    }
}

public enum TranscriptChatPromptComposer {
    public static let defaultSystemPrompt = """
    You are a concise assistant.
    Answer directly and avoid unnecessary verbosity.
    """

    public static func compose(question: String, transcriptContext: String?) -> TranscriptChatPromptPayload {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let transcriptContext,
           !transcriptContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let task = LLMTask.transcriptChat(question: trimmedQuestion, transcript: transcriptContext)
            return TranscriptChatPromptPayload(
                prompt: LLMPromptBuilder.userPrompt(for: task),
                defaultSystemPrompt: LLMPromptBuilder.systemPrompt(for: task)
            )
        }

        return TranscriptChatPromptPayload(
            prompt: trimmedQuestion,
            defaultSystemPrompt: defaultSystemPrompt
        )
    }
}

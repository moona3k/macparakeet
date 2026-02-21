import Foundation

public enum LLMRefinementMode: String, CaseIterable, Sendable {
    case formal
    case email
    case code
}

public enum LLMTask: Sendable {
    case refine(mode: LLMRefinementMode, input: String)
    case commandTransform(command: String, selectedText: String)
    case transcriptChat(question: String, transcript: String)
}

public enum LLMPromptBuilder {
    public static func systemPrompt(for task: LLMTask) -> String {
        switch task {
        case .refine(let mode, _):
            switch mode {
            case .formal:
                return """
                You are a text rewriter. Rewrite the user's text in a formal professional tone.
                CRITICAL: Output ONLY the rewritten text. No introductions, no explanations, no quotes, no "Here's" preamble. Just the text itself.
                """
            case .email:
                return """
                You are a text rewriter. Rewrite the user's text as a polished email body.
                CRITICAL: Output ONLY the rewritten email text. No introductions, no explanations, no quotes, no "Here's" preamble. Just the text itself.
                """
            case .code:
                return """
                You are a text rewriter. Rewrite the user's text while preserving code identifiers, symbols, and formatting.
                CRITICAL: Output ONLY the rewritten text. No introductions, no explanations, no quotes, no "Here's" preamble. Just the text itself.
                """
            }
        case .commandTransform:
            return """
            You execute text-editing commands. Apply the command exactly to the provided text.
            Return only the transformed text.
            """
        case .transcriptChat:
            return """
            You answer questions using only the provided transcript context.
            If context is insufficient, say so briefly.
            """
        }
    }

    public static func userPrompt(for task: LLMTask) -> String {
        switch task {
        case .refine(_, let input):
            return """
            Rewrite this text. Output only the result, nothing else.

            \(input)
            """
        case .commandTransform(let command, let selectedText):
            return """
            Command:
            \(command)

            Selected text:
            \(selectedText)
            """
        case .transcriptChat(let question, let transcript):
            return """
            Transcript:
            \(transcript)

            Question:
            \(question)
            """
        }
    }
}

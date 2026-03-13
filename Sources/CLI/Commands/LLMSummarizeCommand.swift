import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMSummarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Summarize text from a file or stdin using an LLM provider."
    )

    @OptionGroup var llm: LLMInlineOptions

    @Argument(help: "Path to text file to summarize. Use '-' for stdin.")
    var input: String

    @Flag(name: .long, help: "Stream the response token by token.")
    var stream: Bool = false

    func run() async throws {
        let text = try readInput(input)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Input is empty.")
            throw ExitCode.failure
        }

        let config = try llm.buildConfig()
        let client = LLMClient()

        if stream {
            let messages = [
                ChatMessage(role: .system, content: "You are a helpful assistant that summarizes transcripts. Provide a clear, concise summary that captures the key points, decisions, and action items. Use bullet points for clarity. Keep the summary under 500 words."),
                ChatMessage(role: .user, content: text),
            ]
            let tokenStream = client.chatCompletionStream(messages: messages, config: config, options: .default)
            for try await token in tokenStream {
                print(token, terminator: "")
            }
            print()
        } else {
            let messages = [
                ChatMessage(role: .system, content: "You are a helpful assistant that summarizes transcripts. Provide a clear, concise summary that captures the key points, decisions, and action items. Use bullet points for clarity. Keep the summary under 500 words."),
                ChatMessage(role: .user, content: text),
            ]
            let response = try await client.chatCompletion(messages: messages, config: config, options: .default)
            print(response.content)
        }
    }
}

import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Ask a question about a transcript using the configured LLM provider."
    )

    @Argument(help: "Path to transcript text file. Use '-' for stdin.")
    var input: String

    @Option(name: .shortAndLong, help: "Question to ask about the transcript.")
    var question: String

    @Flag(name: .long, help: "Stream the response token by token.")
    var stream: Bool = false

    func run() async throws {
        let text = try readInput(input)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Input is empty.")
            throw ExitCode.failure
        }

        let service = LLMService()

        if stream {
            let tokenStream = service.chatStream(question: question, transcript: text, history: [])
            for try await token in tokenStream {
                print(token, terminator: "")
            }
            print()
        } else {
            let answer = try await service.chat(question: question, transcript: text, history: [])
            print(answer)
        }
    }
}

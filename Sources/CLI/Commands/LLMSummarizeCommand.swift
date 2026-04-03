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

        let execution = try llm.buildExecutionContext()
        let service = LLMService(
            client: execution.client,
            contextResolver: StaticLLMExecutionContextResolver(context: execution.context)
        )

        if stream {
            let tokenStream = service.summarizeStream(transcript: text)
            for try await token in tokenStream {
                print(token, terminator: "")
            }
            print()
        } else {
            print(try await service.summarize(transcript: text))
        }
    }
}

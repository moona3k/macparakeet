import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Ask a question about a transcript using an LLM provider."
    )

    @OptionGroup var llm: LLMInlineOptions

    @Argument(help: "Path to transcript text file. Use '-' for stdin.")
    var input: String

    @Option(name: .shortAndLong, help: "Question to ask about the transcript.")
    var question: String

    @Flag(name: .long, help: "Stream the response token by token.")
    var stream: Bool = false

    @Flag(name: .long, help: "Emit a structured JSON envelope (output, provider, model, usage, stopReason, latencyMs) instead of plain text.")
    var json: Bool = false

    func validate() throws {
        if json && stream {
            throw ValidationError("--json with --stream is not yet supported. Run without --stream for the envelope, or omit --json for token streaming.")
        }
    }

    func run() async throws {
        try await emitJSONOrRethrow(json: json) {
            let text = try readInput(input)

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIInputError.empty
            }

            let execution = try llm.buildExecutionContext()
            let service = LLMService(
                client: execution.client,
                contextResolver: StaticLLMExecutionContextResolver(context: execution.context)
            )

            if json {
                let result = try await service.chatDetailed(question: question, transcript: text, history: [])
                try printJSON(result)
            } else if stream {
                let tokenStream = service.chatStream(question: question, transcript: text, history: [])
                for try await token in tokenStream {
                    print(token, terminator: "")
                }
                print()
            } else {
                print(try await service.chat(question: question, transcript: text, history: []))
            }
        }
    }
}

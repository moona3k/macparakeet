import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMTransformCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transform",
        abstract: "Apply a custom LLM transform to text from a file or stdin."
    )

    @OptionGroup var llm: LLMInlineOptions

    @Argument(help: "Path to text file to transform. Use '-' for stdin.")
    var input: String

    @Option(name: .shortAndLong, help: "Transform instruction (e.g. 'Make it formal', 'Translate to Spanish').")
    var prompt: String

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
            let tokenStream = service.transformStream(text: text, prompt: prompt)
            for try await token in tokenStream {
                print(token, terminator: "")
            }
            print()
        } else {
            print(try await service.transform(text: text, prompt: prompt))
        }
    }
}

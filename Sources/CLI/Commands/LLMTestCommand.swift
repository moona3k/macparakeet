import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-connection",
        abstract: "Test connectivity to an LLM provider."
    )

    @OptionGroup var llm: LLMInlineOptions

    func run() async throws {
        let execution = try llm.buildExecutionContext()
        let config = execution.context.providerConfig

        print("Testing connection to \(config.id.displayName) (\(config.modelName))...")

        do {
            try await execution.client.testConnection(context: execution.context)
            print("Connection successful.")
        } catch let error as LLMError {
            print("Connection failed: \(error.errorDescription ?? String(describing: error))")
            throw ExitCode.failure
        }
    }
}

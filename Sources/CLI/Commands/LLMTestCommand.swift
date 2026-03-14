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
        let config = try llm.buildConfig()

        print("Testing connection to \(config.id.displayName) (\(config.modelName))...")

        let client = LLMClient()
        do {
            try await client.testConnection(config: config)
            print("Connection successful.")
        } catch let error as LLMError {
            print("Connection failed: \(error.errorDescription ?? String(describing: error))")
            throw ExitCode.failure
        }
    }
}

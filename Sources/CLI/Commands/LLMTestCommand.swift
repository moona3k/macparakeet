import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-connection",
        abstract: "Test connectivity to the configured LLM provider."
    )

    func run() async throws {
        let store = LLMConfigStore()

        guard let config = try store.loadConfig() else {
            print("No LLM provider configured. Run 'macparakeet-cli llm config' first.")
            throw ExitCode.failure
        }

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

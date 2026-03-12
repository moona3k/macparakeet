import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show current LLM provider configuration."
    )

    func run() async throws {
        let store = LLMConfigStore()

        print("LLM Provider Status")
        print("====================")
        print()

        guard let config = try store.loadConfig() else {
            print("  No provider configured.")
            print()
            print("  Configure one with:")
            print("    macparakeet-cli llm config --provider openai --api-key sk-... --model gpt-4o")
            return
        }

        print("  Provider:  \(config.id.displayName)")
        print("  Base URL:  \(config.baseURL)")
        print("  Model:     \(config.modelName)")
        print("  Local:     \(config.isLocal)")
        print("  API Key:   \(config.apiKey != nil ? "••••\(String(config.apiKey!.suffix(4)))" : "(none)")")
    }
}

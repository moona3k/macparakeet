import ArgumentParser

struct LLMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "llm",
        abstract: "LLM provider commands (config, test, summarize, chat, transform).",
        subcommands: [
            LLMStatusCommand.self,
            LLMTestCommand.self,
            LLMConfigCommand.self,
            LLMSummarizeCommand.self,
            LLMChatCommand.self,
            LLMTransformCommand.self,
        ]
    )
}

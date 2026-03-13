import ArgumentParser

struct LLMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "llm",
        abstract: "LLM provider commands (test, summarize, chat, transform).",
        subcommands: [
            LLMTestCommand.self,
            LLMSummarizeCommand.self,
            LLMChatCommand.self,
            LLMTransformCommand.self,
        ]
    )
}

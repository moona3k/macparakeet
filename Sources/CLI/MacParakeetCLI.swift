import ArgumentParser

@main
struct CLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macparakeet-cli",
        abstract: "MacParakeet developer CLI (internal; used for AI-assisted development and testing).",
        version: "0.1.0",
        subcommands: [
            TranscribeCommand.self,
            HistoryCommand.self,
            HealthCommand.self,
            ModelsCommand.self,
            FlowCommand.self,
            LLMCommand.self,
        ],
        defaultSubcommand: nil
    )
}

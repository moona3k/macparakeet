import ArgumentParser

@main
struct CLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macparakeet",
        abstract: "MacParakeet — fast, private, local-first voice tools for macOS.",
        version: "0.1.0",
        subcommands: [
            TranscribeCommand.self,
            HistoryCommand.self,
            HealthCommand.self,
            FlowCommand.self,
        ],
        defaultSubcommand: nil
    )
}

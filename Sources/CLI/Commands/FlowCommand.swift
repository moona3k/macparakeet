import ArgumentParser

struct FlowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flow",
        abstract: "Text processing pipeline commands.",
        subcommands: [
            FlowProcessCommand.self,
            FlowWordsCommand.self,
            FlowSnippetsCommand.self,
        ]
    )
}

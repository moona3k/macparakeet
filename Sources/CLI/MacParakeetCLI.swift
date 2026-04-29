import ArgumentParser
import Darwin

@main
struct CLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macparakeet-cli",
        abstract: "Local STT, transcription, and prompt automation for Apple Silicon. Powered by Parakeet TDT, with optional Whisper multilingual recognition.",
        version: "1.4.0",
        subcommands: [
            TranscribeCommand.self,
            HistoryCommand.self,
            ExportCommand.self,
            StatsCommand.self,
            HealthCommand.self,
            ConfigCommand.self,
            ModelsCommand.self,
            FlowCommand.self,
            LLMCommand.self,
            PromptsCommand.self,
            MeetingsCommand.self,
            CalendarCommand.self,
            FeedbackCommand.self,
        ],
        defaultSubcommand: nil
    )

    static func main() async {
        await main(nil)
    }

    static func main(_ arguments: [String]?) async {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exitWithNormalizedError(error)
        }
    }

    static func normalizedExitCode(for error: Error) -> ExitCode {
        if let exitCode = error as? ExitCode {
            return normalizedExitCode(for: exitCode)
        }
        return normalizedExitCode(for: exitCode(for: error))
    }

    static func normalizedExitCode(for exitCode: ExitCode) -> ExitCode {
        exitCode == .validationFailure ? cliValidationMisuseExitCode : exitCode
    }

    private static func exitWithNormalizedError(_ error: Error) -> Never {
        let exitCode = normalizedExitCode(for: error)
        let message = fullMessage(for: error)
        if !message.isEmpty {
            if exitCode.isSuccess {
                print(message)
            } else {
                printErr(message)
            }
        }
        Darwin.exit(exitCode.rawValue)
    }
}

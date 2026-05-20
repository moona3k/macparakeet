import ArgumentParser
import Darwin

@main
struct CLI: AsyncParsableCommand {
    /// Single source of truth for the CLI's semver. Surfaced via ArgumentParser's
    /// `--version` and reported as `app_ver` to telemetry so CLI sessions are
    /// distinguishable from synthesized Bundle.main values (the bare executable
    /// has no Info.plist and macOS otherwise reports an SDK marker like "16.0").
    /// Bump in lockstep with `Sources/CLI/CHANGELOG.md`.
    static let cliVersion = "2.3.1"

    static let configuration = CommandConfiguration(
        commandName: "macparakeet-cli",
        abstract: "Local STT, transcription, and prompt automation for Apple Silicon. Powered by Parakeet TDT, with optional Whisper multilingual recognition.",
        version: cliVersion,
        subcommands: [
            TranscribeCommand.self,
            HistoryCommand.self,
            ExportCommand.self,
            StatsCommand.self,
            HealthCommand.self,
            ConfigCommand.self,
            ModelsCommand.self,
            VocabCommand.self,
            LLMCommand.self,
            PromptsCommand.self,
            QuickPromptsCommand.self,
            TransformsCommand.self,
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

import ArgumentParser
import Foundation
import MacParakeetCore

protocol CLITelemetryMetadataProviding {
    var cliTelemetryMetadata: CLITelemetry.OperationMetadata { get }
}

enum CLITelemetry {
    struct OperationMetadata: Equatable, Sendable {
        var command: String
        var subcommand: String?
        var inputKind: ObservabilityInputKind?
        var outputFormat: String?
        var json: Bool?
        var suppressEvent: Bool

        init(
            command: String,
            subcommand: String? = nil,
            inputKind: ObservabilityInputKind? = nil,
            outputFormat: String? = nil,
            json: Bool? = nil,
            suppressEvent: Bool = false
        ) {
            self.command = command
            self.subcommand = subcommand
            self.inputKind = inputKind
            self.outputFormat = outputFormat
            self.json = json
            self.suppressEvent = suppressEvent
        }
    }

    typealias EnvOverride = TelemetryPolicy.EnvOverride

    static func configureIfNeeded(env: [String: String] = ProcessInfo.processInfo.environment) {
        switch decideOverride(env: env) {
        case .forceOff, .ciAutoDisable:
            Telemetry.configure(NoOpTelemetryService())
        case .forceOn:
            Telemetry.configure(TelemetryService(
                requestTimeoutInterval: 1.0,
                surface: "cli",
                appVersionOverride: CLI.cliVersion,
                isEnabled: { true }
            ))
        case .none:
            Telemetry.configure(TelemetryService(
                requestTimeoutInterval: 1.0,
                surface: "cli",
                appVersionOverride: CLI.cliVersion,
                isEnabled: {
                    AppPreferences.isTelemetryEnabled(defaults: macParakeetAppDefaults())
                }
            ))
        }
    }

    static func decideOverride(env: [String: String]) -> EnvOverride {
        TelemetryPolicy.decideOverride(env: env)
    }

    static func isCIEnvironment(env: [String: String]) -> Bool {
        TelemetryPolicy.isCIEnvironment(env: env)
    }

    static func runInstrumented(_ command: inout ParsableCommand) async throws {
        let metadata = metadata(for: command)
        if metadata.suppressEvent {
            Telemetry.configure(NoOpTelemetryService())
        } else {
            configureIfNeeded()
        }
        let operationContext = ObservabilityOperationContext()
        let operationID = operationContext.operationID
        let startedAt = operationContext.startedAt
        let result: Result<Void, Error>

        do {
            try await Observability.withOperationContext(operationContext) {
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }

        if !metadata.suppressEvent {
            await sendOperationAndFlush(
                operationID: operationID,
                operationContext: operationContext,
                command: metadata.command,
                subcommand: metadata.subcommand,
                outcome: result.cliTelemetryOutcome,
                startedAt: startedAt,
                inputKind: metadata.inputKind,
                outputFormat: metadata.outputFormat,
                json: metadata.json,
                exitCode: result.cliTelemetryExitCode,
                errorType: result.cliTelemetryErrorType
            )
        }

        try result.get()
    }

    static func metadata(for command: ParsableCommand) -> OperationMetadata {
        if let provider = command as? CLITelemetryMetadataProviding {
            return provider.cliTelemetryMetadata
        }

        let commandType = type(of: command)
        let path = commandPath(for: commandType) ?? [
            commandType.configuration.commandName ?? String(describing: commandType)
        ]
        let commandName = path[0]
        let subcommand = path.dropFirst().isEmpty ? nil : path.dropFirst().joined(separator: " ")
        return OperationMetadata(command: commandName, subcommand: subcommand)
    }

    private static func commandPath(for target: ParsableCommand.Type) -> [String]? {
        commandPath(through: CLI.configuration.subcommands, target: target)
    }

    private static func commandPath(
        through commandTypes: [ParsableCommand.Type],
        target: ParsableCommand.Type
    ) -> [String]? {
        for commandType in commandTypes {
            let name = commandType.configuration.commandName ?? String(describing: commandType)
            if commandType == target {
                return [name]
            }
            if let childPath = commandPath(through: commandType.configuration.subcommands, target: target) {
                return [name] + childPath
            }
        }
        return nil
    }

    static func sendOperationAndFlush(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        command: String,
        subcommand: String? = nil,
        outcome: ObservabilityOutcome,
        startedAt: Date,
        inputKind: ObservabilityInputKind? = nil,
        outputFormat: String? = nil,
        json: Bool? = nil,
        exitCode: Int? = nil,
        errorType: String? = nil
    ) async {
        Telemetry.send(.cliOperation(
            operationID: operationID,
            operationContext: operationContext,
            command: command,
            subcommand: subcommand,
            outcome: outcome,
            durationSeconds: Observability.durationSeconds(since: startedAt),
            inputKind: inputKind,
            outputFormat: outputFormat,
            json: json,
            exitCode: exitCode,
            errorType: errorType
        ))
        await Telemetry.flush()
    }
}

extension Result where Success == Void, Failure == Error {
    var cliTelemetryOutcome: ObservabilityOutcome {
        switch self {
        case .success:
            return .success
        case .failure(let error):
            return CLI.normalizedExitCode(for: error).isSuccess ? .success : .failure
        }
    }

    var cliTelemetryExitCode: Int {
        switch self {
        case .success:
            return 0
        case .failure(let error):
            return Int(CLI.normalizedExitCode(for: error).rawValue)
        }
    }

    var cliTelemetryErrorType: String? {
        switch self {
        case .success:
            return nil
        case .failure(let error):
            // ArgumentParser uses successful thrown exits for help and other
            // early completions. They must not carry a runtime error bucket.
            guard !CLI.normalizedExitCode(for: error).isSuccess else { return nil }
            if let jsonExit = error as? CLIJSONEnvelopeExit {
                return CLIErrorType.key(for: jsonExit.originalError)
            }
            return CLIErrorType.key(for: error)
        }
    }
}

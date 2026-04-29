import Foundation
import MacParakeetCore

enum CLITelemetry {
    /// Outcome of evaluating env-var overrides for CLI telemetry. Resolved before
    /// the user's persisted UserDefaults preference is consulted.
    enum EnvOverride: Equatable {
        /// `MACPARAKEET_TELEMETRY=1/true/yes/on` — explicit force-on, defeats CI auto-disable.
        case forceOn
        /// `MACPARAKEET_TELEMETRY=0/false/no/off` or `DO_NOT_TRACK=1` — explicit force-off.
        case forceOff
        /// Headless CI context (`CI=true`, `GITHUB_ACTIONS=true`, etc.) with no explicit override.
        case ciAutoDisable
        /// No override; honor the persisted UserDefaults `telemetryEnabled` preference.
        case none
    }

    static func configureIfNeeded(env: [String: String] = ProcessInfo.processInfo.environment) {
        switch decideOverride(env: env) {
        case .forceOff, .ciAutoDisable:
            Telemetry.configure(NoOpTelemetryService())
        case .forceOn:
            Telemetry.configure(TelemetryService(
                requestTimeoutInterval: 1.0,
                isEnabled: { true }
            ))
        case .none:
            Telemetry.configure(TelemetryService(
                requestTimeoutInterval: 1.0,
                isEnabled: {
                    AppPreferences.isTelemetryEnabled(defaults: macParakeetAppDefaults())
                }
            ))
        }
    }

    /// Pure decision function — testable without ProcessInfo or UserDefaults state.
    /// `MACPARAKEET_TELEMETRY` wins outright. Then `DO_NOT_TRACK=1` (industry-standard,
    /// honored by Homebrew, GitLab, VS Code, etc.). Then CI auto-disable so a 1000-job
    /// agent run in GitHub Actions doesn't silently flood the endpoint with `cli_operation`
    /// events.
    static func decideOverride(env: [String: String]) -> EnvOverride {
        if let raw = env["MACPARAKEET_TELEMETRY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty {
            if ["0", "false", "no", "off"].contains(raw) { return .forceOff }
            if ["1", "true", "yes", "on"].contains(raw) { return .forceOn }
        }

        if let dnt = env["DO_NOT_TRACK"]?.trimmingCharacters(in: .whitespacesAndNewlines), dnt == "1" {
            return .forceOff
        }

        if isCIEnvironment(env: env) {
            return .ciAutoDisable
        }

        return .none
    }

    /// Variables that conventionally mark a CI/automation context.
    /// Hoisted out of `isCIEnvironment` so it isn't reallocated per call.
    private static let ciEnvVars: [String] = [
        "CI",
        "GITHUB_ACTIONS",
        "GITLAB_CI",
        "BUILDKITE",
        "CIRCLECI",
        "TRAVIS",
        "JENKINS_URL",
        "TF_BUILD",
        "TEAMCITY_VERSION"
    ]

    /// Detects common CI/automation contexts. Conservative: only treats a variable as
    /// CI-positive when it's set to a truthy value, so `CI=false` (yes, some setups
    /// pass that) does not trigger auto-disable.
    static func isCIEnvironment(env: [String: String]) -> Bool {
        for name in ciEnvVars {
            guard let raw = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            let lower = raw.lowercased()
            if lower == "false" || lower == "0" || lower == "no" || lower == "off" {
                continue
            }
            return true
        }
        return false
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

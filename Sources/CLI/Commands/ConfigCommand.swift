import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli config` — read or write app preferences from the CLI.
///
/// Stores values in the same UserDefaults suite the GUI reads
/// (`com.macparakeet.MacParakeet`). This lets users who only install the CLI
/// (no GUI) persist preferences like opting out of telemetry — and a later GUI
/// install picks the same values up automatically. Without this, CLI-only
/// users would have no way to opt out of telemetry except per-process env vars.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read or write CLI/app configuration values.",
        discussion: """
        Configuration is stored in the shared MacParakeet UserDefaults suite \
        (com.macparakeet.MacParakeet). The GUI reads the same suite, so values \
        set here apply to both surfaces.

        Supported keys:
          telemetry   on|off   Anonymous, non-identifying usage analytics
                               (default: on)

        Full event catalog:
          https://github.com/moona3k/macparakeet/blob/main/docs/telemetry.md

        Per-process overrides (env vars, do not require `config set`):
          MACPARAKEET_TELEMETRY=0   Force-off for one invocation
          MACPARAKEET_TELEMETRY=1   Force-on for one invocation
          DO_NOT_TRACK=1            Force-off (industry-standard signal)
          CI=true                   Auto-disabled in CI environments
        """,
        subcommands: [GetCommand.self, SetCommand.self, ListCommand.self]
    )

    /// Keys recognized by `get`/`set`/`list`.
    static let supportedKeys: [String] = ["telemetry"]

    // MARK: - Subcommands

    struct GetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print the current value of a configuration key."
        )

        @Argument(help: "Configuration key. Supported: \(ConfigCommand.supportedKeys.joined(separator: ", ")).")
        var key: String

        @Flag(name: .long, help: "Emit JSON instead of plain text.")
        var json: Bool = false

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let value = try ConfigCommand.read(key: key)
                try printResult(key: key, value: value, json: json)
            }
        }
    }

    struct SetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Write a configuration value."
        )

        @Argument(help: "Configuration key. Supported: \(ConfigCommand.supportedKeys.joined(separator: ", ")).")
        var key: String

        @Argument(help: "Value (e.g. on/off, true/false, 1/0).")
        var value: String

        @Flag(name: .long, help: "Emit JSON instead of plain text.")
        var json: Bool = false

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let written = try ConfigCommand.write(key: key, value: value)
                try printResult(key: key, value: written, json: json)
            }
        }
    }

    struct ListCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Print all configurable keys and their current values."
        )

        @Flag(name: .long, help: "Emit JSON instead of plain text.")
        var json: Bool = false

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                var entries: [(String, String)] = []
                for key in ConfigCommand.supportedKeys {
                    entries.append((key, try ConfigCommand.read(key: key)))
                }
                if json {
                    let dict = Dictionary(uniqueKeysWithValues: entries)
                    try printJSON(dict)
                } else {
                    for (key, value) in entries {
                        print("\(key) = \(value)")
                    }
                }
            }
        }
    }

    // MARK: - Read / Write
    //
    // Both throw `ValidationError` for unsupported keys / invalid values so the
    // CLI's `--json` failure envelope contract picks them up with
    // `errorType: "validation"` and exit code 2 (misuse). See
    // `Sources/CLI/CHANGELOG.md` "Exit codes" / "--json failure envelope".

    static func read(key: String, defaults: UserDefaults? = nil) throws -> String {
        let store = defaults ?? macParakeetAppDefaults()
        switch key {
        case "telemetry":
            let on = AppPreferences.isTelemetryEnabled(defaults: store)
            return on ? "on" : "off"
        default:
            throw unknownKeyError(key)
        }
    }

    /// Writes the value and returns the canonical normalized form actually persisted
    /// (e.g. "on"/"off" for booleans).
    @discardableResult
    static func write(key: String, value: String, defaults: UserDefaults? = nil) throws -> String {
        let store = defaults ?? macParakeetAppDefaults()
        switch key {
        case "telemetry":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: AppPreferences.telemetryEnabledKey)
            return parsed ? "on" : "off"
        default:
            throw unknownKeyError(key)
        }
    }

    static func parseBool(_ value: String, key: String) throws -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch v {
        case "on", "true", "yes", "1", "enable", "enabled":
            return true
        case "off", "false", "no", "0", "disable", "disabled":
            return false
        default:
            throw ValidationError("Invalid value for \(key): '\(value)'. Use on/off (or true/false, yes/no, 1/0).")
        }
    }

    private static func unknownKeyError(_ key: String) -> ValidationError {
        ValidationError("Unknown config key: '\(key)'. Supported: \(ConfigCommand.supportedKeys.joined(separator: ", ")).")
    }
}

private struct ConfigKeyValue: Encodable {
    let key: String
    let value: String
}

private func printResult(key: String, value: String, json: Bool) throws {
    if json {
        try printJSON(ConfigKeyValue(key: key, value: value))
    } else {
        print(value)
    }
}

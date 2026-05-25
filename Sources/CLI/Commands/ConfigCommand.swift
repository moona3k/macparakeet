import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli config` — read or write app preferences from the CLI.
///
/// Stores values in the same UserDefaults suite the GUI reads
/// (`com.macparakeet.MacParakeet`). This lets users who only install the CLI
/// (no GUI) persist preferences like opting out of telemetry — and a later GUI
/// install picks the same values up automatically. Without this, CLI-only
/// users would have no way to opt out of telemetry or set app-default
/// transcription state for agent-driven smoke tests.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read or write CLI/app configuration values.",
        discussion: """
        Configuration is stored in the shared MacParakeet UserDefaults suite \
        (com.macparakeet.MacParakeet). The GUI and CLI read the same suite, so \
        values set here apply to later app-default reads. A running GUI may \
        cache some settings until relaunch or an in-app change.

        Supported keys:
          telemetry                 on|off                         default: on
          processing-mode           raw|clean                       default: raw
          speech-engine             parakeet|whisper                default: parakeet
          whisper-language          auto|<Whisper language code>    default: auto
          speaker-detection         on|off                          default: off
          save-transcription-audio  on|off                          default: on
          youtube-audio-quality     m4a|best-available              default: m4a

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
    static let supportedKeys: [String] = [
        "telemetry",
        "processing-mode",
        "speech-engine",
        "whisper-language",
        "speaker-detection",
        "save-transcription-audio",
        "youtube-audio-quality",
    ]

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
                let canonicalKey = try ConfigCommand.canonicalKey(key)
                let value = try ConfigCommand.read(key: canonicalKey)
                try printResult(key: canonicalKey, value: value, json: json)
            }
        }
    }

    struct SetCommand: ParsableCommand, CLITelemetryMetadataProviding {
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

        var cliTelemetryMetadata: CLITelemetry.OperationMetadata {
            CLITelemetry.OperationMetadata(
                command: ConfigCommand.configuration.commandName ?? "config",
                subcommand: Self.configuration.commandName ?? "set",
                json: json,
                suppressEvent: Self.suppressesTelemetryEvent(key: key, value: value)
            )
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let canonicalKey = try ConfigCommand.canonicalKey(key)
                let written = try ConfigCommand.write(key: canonicalKey, value: value)
                try printResult(key: canonicalKey, value: written, json: json)
            }
        }

        static func suppressesTelemetryEvent(key: String, value: String) -> Bool {
            (try? ConfigCommand.canonicalKey(key)) == "telemetry"
                && (try? ConfigCommand.parseBool(value, key: key)) == false
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
        switch try canonicalKey(key) {
        case "telemetry":
            let on = AppPreferences.isTelemetryEnabled(defaults: store)
            return on ? "on" : "off"
        case "processing-mode":
            let raw = store.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey)
            return (Dictation.ProcessingMode(rawValue: raw ?? Dictation.ProcessingMode.raw.rawValue) ?? .raw).rawValue
        case "speech-engine":
            return SpeechEnginePreference.current(defaults: store).rawValue
        case "whisper-language":
            return SpeechEnginePreference.whisperDefaultLanguage(defaults: store) ?? WhisperLanguageCatalog.autoCode
        case "speaker-detection":
            let on = store.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool ?? false
            return on ? "on" : "off"
        case "save-transcription-audio":
            let on = store.object(forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey) as? Bool ?? true
            return on ? "on" : "off"
        case "youtube-audio-quality":
            return displayYouTubeAudioQuality(YouTubeAudioQuality.current(defaults: store))
        default:
            throw unknownKeyError(key)
        }
    }

    /// Writes the value and returns the canonical normalized form actually persisted
    /// (e.g. "on"/"off" for booleans).
    @discardableResult
    static func write(key: String, value: String, defaults: UserDefaults? = nil) throws -> String {
        let store = defaults ?? macParakeetAppDefaults()
        switch try canonicalKey(key) {
        case "telemetry":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: AppPreferences.telemetryEnabledKey)
            return parsed ? "on" : "off"
        case "processing-mode":
            let mode = try parseProcessingMode(value)
            store.set(mode.rawValue, forKey: UserDefaultsAppRuntimePreferences.processingModeKey)
            return mode.rawValue
        case "speech-engine":
            let engine = try parseSpeechEngine(value)
            engine.save(to: store)
            return engine.rawValue
        case "whisper-language":
            let language = try parseWhisperLanguage(value)
            SpeechEnginePreference.saveWhisperDefaultLanguage(language, defaults: store)
            return language ?? WhisperLanguageCatalog.autoCode
        case "speaker-detection":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey)
            return parsed ? "on" : "off"
        case "save-transcription-audio":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey)
            return parsed ? "on" : "off"
        case "youtube-audio-quality":
            let quality = try parseYouTubeAudioQuality(value)
            store.set(quality.rawValue, forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey)
            return displayYouTubeAudioQuality(quality)
        default:
            throw unknownKeyError(key)
        }
    }

    static func canonicalKey(_ key: String) throws -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if supportedKeys.contains(normalized) {
            return normalized
        }
        throw unknownKeyError(key)
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

    static func parseProcessingMode(_ value: String) throws -> Dictation.ProcessingMode {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = Dictation.ProcessingMode(rawValue: raw) else {
            throw ValidationError("Invalid value for processing-mode: '\(value)'. Use raw or clean.")
        }
        return mode
    }

    static func parseSpeechEngine(_ value: String) throws -> SpeechEnginePreference {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let engine = SpeechEnginePreference(rawValue: raw) else {
            throw ValidationError("Invalid value for speech-engine: '\(value)'. Use parakeet or whisper.")
        }
        return engine
    }

    static func parseWhisperLanguage(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == WhisperLanguageCatalog.autoCode || lowered == "auto-detect" {
            return nil
        }
        guard let language = SpeechEnginePreference.normalizeLanguage(trimmed) else {
            throw ValidationError("Invalid value for whisper-language: '\(value)'. Use auto or a Whisper language code.")
        }
        return language
    }

    static func parseYouTubeAudioQuality(_ value: String) throws -> YouTubeAudioQuality {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch raw {
        case "m4a":
            return .m4a
        case "best-available", "bestavailable":
            return .bestAvailable
        default:
            throw ValidationError("Invalid value for youtube-audio-quality: '\(value)'. Use m4a or best-available.")
        }
    }

    static func displayYouTubeAudioQuality(_ quality: YouTubeAudioQuality) -> String {
        switch quality {
        case .m4a:
            return "m4a"
        case .bestAvailable:
            return "best-available"
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

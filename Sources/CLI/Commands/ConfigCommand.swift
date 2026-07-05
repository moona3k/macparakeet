import ArgumentParser
import Foundation
import MacParakeetCore

struct CLIConfigKeySpec: Encodable, Equatable {
    let key: String
    let valueSyntax: String
    let allowedValues: [String]?
    let summary: String
}

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
          speech-engine             parakeet|nemotron|whisper|cohere default: parakeet
          parakeet-model            v3|v2|unified                   default: v3
                                    (v3=supported languages, v2=English
                                    timestamps, unified=English no timestamps)
          nemotron-model            multilingual-1120ms|            default: multilingual-1120ms
                                    english-1120ms (Beta streaming)
          nemotron-language         auto|<Nemotron language code>   default: auto
                                    (multilingual build only)
          whisper-language          auto|<Whisper language code>    default: auto
          cohere-language           <Cohere language code>          default: en (no auto)
          speaker-detection         on|off                          default: on
          meeting-speaker-detection on|off                          default: on
          auto-meeting-titles       on|off                          default: on
          voice-return-enabled      on|off                          default: off
          voice-return-triggers     phrase[|phrase...]              default: press return
          save-transcription-audio  on|off                          default: on
          meeting-audio-retention   keep-forever|                   default: keep-forever
                                    delete-after-<1-365>-days|
                                    <1-365>d|
                                    delete-immediately
          meeting-audio-source      microphone-and-system|          default: microphone-and-system
                                    microphone-only|
                                    system-only
          prefer-built-in-mic-bluetooth-output on|off               default: on
          save-meeting-audio        on|off                          legacy alias
          youtube-audio-quality     m4a|best-available              default: m4a
          meeting-artifacts-folder  absolute path|default           default: app support
          meeting-hook-enabled      on|off                          default: off
          meeting-hook-path         absolute executable path|none    default: none
          meeting-hook-timeout      seconds (1-300)                 default: 20

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
    static let supportedKeySpecs: [CLIConfigKeySpec] = [
        CLIConfigKeySpec(
            key: "telemetry",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Enable or disable telemetry."
        ),
        CLIConfigKeySpec(
            key: "processing-mode",
            valueSyntax: "raw|clean",
            allowedValues: ["raw", "clean"],
            summary: "Default dictation text processing mode."
        ),
        CLIConfigKeySpec(
            key: "speech-engine",
            valueSyntax: "parakeet|nemotron|whisper|cohere",
            allowedValues: ["parakeet", "nemotron", "whisper", "cohere"],
            summary: "Default speech recognition engine for app-default transcription."
        ),
        CLIConfigKeySpec(
            key: "parakeet-model",
            valueSyntax: "v3|v2|unified",
            allowedValues: ["v3", "v2", "unified"],
            summary: "Default Parakeet build: v3 supported languages, v2 English timestamps, or Unified readable English without timestamps."
        ),
        CLIConfigKeySpec(
            key: "nemotron-model",
            valueSyntax: "multilingual-1120ms|english-1120ms",
            allowedValues: ["multilingual-1120ms", "english-1120ms"],
            summary: "Default Nemotron Beta streaming build."
        ),
        CLIConfigKeySpec(
            key: "nemotron-language",
            valueSyntax: "auto|<Nemotron language code>",
            allowedValues: nil,
            summary: "Default Nemotron language hint for the multilingual build; auto uses engine detection when available."
        ),
        CLIConfigKeySpec(
            key: "whisper-language",
            valueSyntax: "auto|<Whisper language code>",
            allowedValues: nil,
            summary: "Default Whisper language hint; auto detects when possible."
        ),
        CLIConfigKeySpec(
            key: "cohere-language",
            valueSyntax: CohereTranscribeEngine.supportedLanguages.map(\.code).joined(separator: "|"),
            allowedValues: CohereTranscribeEngine.supportedLanguages.map(\.code),
            summary: "Default Cohere Transcribe language; Cohere has no auto-detect."
        ),
        CLIConfigKeySpec(
            key: "speaker-detection",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Default file and URL transcription speaker detection."
        ),
        CLIConfigKeySpec(
            key: "meeting-speaker-detection",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Default meeting recording speaker detection."
        ),
        CLIConfigKeySpec(
            key: "auto-meeting-titles",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Enable or disable automatic meeting title generation."
        ),
        CLIConfigKeySpec(
            key: "voice-return-enabled",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Enable or disable Voice Return phrase insertion."
        ),
        CLIConfigKeySpec(
            key: "voice-return-triggers",
            valueSyntax: "phrase[|phrase...]",
            allowedValues: nil,
            summary: "Voice Return trigger phrases separated by |."
        ),
        CLIConfigKeySpec(
            key: "save-transcription-audio",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Persist source audio for file/media transcriptions."
        ),
        CLIConfigKeySpec(
            key: "meeting-audio-retention",
            valueSyntax: "keep-forever|delete-immediately|delete-after-<1-365>-days|<1-365>d",
            allowedValues: nil,
            summary: "Meeting audio retention policy."
        ),
        CLIConfigKeySpec(
            key: "meeting-audio-source",
            valueSyntax: "microphone-and-system|microphone-only|system-only",
            allowedValues: ["microphone-and-system", "microphone-only", "system-only"],
            summary: "Default meeting capture source mode."
        ),
        CLIConfigKeySpec(
            key: "prefer-built-in-mic-bluetooth-output",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Prefer the built-in mic while output is routed to Bluetooth."
        ),
        CLIConfigKeySpec(
            key: "save-meeting-audio",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Legacy alias for meeting audio retention."
        ),
        CLIConfigKeySpec(
            key: "youtube-audio-quality",
            valueSyntax: "m4a|best-available",
            allowedValues: ["m4a", "best-available"],
            summary: "Downloaded media audio quality."
        ),
        CLIConfigKeySpec(
            key: "meeting-artifacts-folder",
            valueSyntax: "absolute path|default",
            allowedValues: ["default"],
            summary: "Meeting artifact folder override."
        ),
        CLIConfigKeySpec(
            key: "meeting-hook-enabled",
            valueSyntax: "on|off",
            allowedValues: ["on", "off"],
            summary: "Enable or disable the meeting automation hook."
        ),
        CLIConfigKeySpec(
            key: "meeting-hook-path",
            valueSyntax: "absolute executable path|none",
            allowedValues: ["none"],
            summary: "Executable invoked by the meeting automation hook."
        ),
        CLIConfigKeySpec(
            key: "meeting-hook-timeout",
            valueSyntax: "seconds 1-300",
            allowedValues: nil,
            summary: "Meeting automation hook timeout in seconds."
        ),
    ]
    static let supportedKeys: [String] = supportedKeySpecs.map(\.key)

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
        case "parakeet-model":
            return SpeechEnginePreference.parakeetModelVariant(defaults: store).rawValue
        case "nemotron-model":
            return SpeechEnginePreference.nemotronModelVariant(defaults: store).rawValue
        case "nemotron-language":
            return SpeechEnginePreference.nemotronDefaultLanguage(defaults: store) ?? "auto"
        case "whisper-language":
            return SpeechEnginePreference.whisperDefaultLanguage(defaults: store) ?? WhisperLanguageCatalog.autoCode
        case "cohere-language":
            return SpeechEnginePreference.cohereDefaultLanguage(defaults: store) ?? "en"
        case "speaker-detection":
            let on = UserDefaultsAppRuntimePreferences.speakerDiarizationEnabled(defaults: store)
            return on ? "on" : "off"
        case "meeting-speaker-detection":
            let on = UserDefaultsAppRuntimePreferences.meetingSpeakerDiarizationEnabled(defaults: store)
            return on ? "on" : "off"
        case "auto-meeting-titles":
            let on = store.object(forKey: UserDefaultsAppRuntimePreferences.autoGenerateMeetingTitlesKey) as? Bool ?? true
            return on ? "on" : "off"
        case "voice-return-enabled":
            let on = store.object(forKey: UserDefaultsAppRuntimePreferences.voiceReturnEnabledKey) as? Bool ?? false
            return on ? "on" : "off"
        case "voice-return-triggers":
            return displayVoiceReturnTriggers(
                UserDefaultsAppRuntimePreferences.voiceReturnTriggerList(defaults: store)
            )
        case "save-transcription-audio":
            let on = store.object(forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey) as? Bool ?? true
            return on ? "on" : "off"
        case "meeting-audio-retention":
            return UserDefaultsAppRuntimePreferences.meetingAudioRetention(defaults: store).configurationValue
        case "meeting-audio-source":
            return MeetingAudioSourceMode.current(defaults: store).configurationValue
        case "prefer-built-in-mic-bluetooth-output":
            let on = store.object(
                forKey: UserDefaultsAppRuntimePreferences.preferBuiltInMicWhenBluetoothOutputKey
            ) as? Bool ?? true
            return on ? "on" : "off"
        case "save-meeting-audio":
            let on = UserDefaultsAppRuntimePreferences(defaults: store).shouldSaveMeetingAudio
            return on ? "on" : "off"
        case "youtube-audio-quality":
            return displayYouTubeAudioQuality(YouTubeAudioQuality.current(defaults: store))
        case "meeting-artifacts-folder":
            return AppPaths.configuredMeetingRecordingsDir(defaults: store)
        case "meeting-hook-enabled":
            let on = store.object(forKey: MeetingAutomationHookConfiguration.enabledKey) as? Bool ?? false
            return on ? "on" : "off"
        case "meeting-hook-path":
            return store.string(forKey: MeetingAutomationHookConfiguration.executablePathKey)
                .flatMap { MeetingAutomationHookConfiguration.normalizedExecutablePath($0) }
                ?? "none"
        case "meeting-hook-timeout":
            let timeout = store.object(forKey: MeetingAutomationHookConfiguration.timeoutSecondsKey) as? Double
                ?? MeetingAutomationHookConfiguration.defaultTimeoutSeconds
            return displayTimeout(MeetingAutomationHookConfiguration.clampedTimeout(timeout))
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
        case "parakeet-model":
            let variant = try parseParakeetModelVariant(value)
            SpeechEnginePreference.saveParakeetModelVariant(variant, defaults: store)
            return variant.rawValue
        case "nemotron-model":
            let variant = try parseNemotronModelVariant(value)
            SpeechEnginePreference.saveNemotronModelVariant(variant, defaults: store)
            return variant.rawValue
        case "nemotron-language":
            let language = try parseNemotronLanguage(value)
            SpeechEnginePreference.saveNemotronDefaultLanguage(language, defaults: store)
            // The value persists either way (it applies the moment the
            // multilingual build is selected again); the note goes to stderr so
            // stdout/--json output stays contract-stable.
            if SpeechEnginePreference.nemotronModelVariant(defaults: store).isEnglishOnly {
                printErr("Note: nemotron-model is english-1120ms; nemotron-language applies only to the multilingual build.")
            }
            return language ?? "auto"
        case "whisper-language":
            let language = try parseWhisperLanguage(value)
            SpeechEnginePreference.saveWhisperDefaultLanguage(language, defaults: store)
            return language ?? WhisperLanguageCatalog.autoCode
        case "cohere-language":
            let language = try parseCohereLanguage(value)
            SpeechEnginePreference.saveCohereDefaultLanguage(language, defaults: store)
            return language
        case "speaker-detection":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey)
            return parsed ? "on" : "off"
        case "meeting-speaker-detection":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: UserDefaultsAppRuntimePreferences.meetingSpeakerDiarizationKey)
            return parsed ? "on" : "off"
        case "auto-meeting-titles":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: UserDefaultsAppRuntimePreferences.autoGenerateMeetingTitlesKey)
            return parsed ? "on" : "off"
        case "voice-return-enabled":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: UserDefaultsAppRuntimePreferences.voiceReturnEnabledKey)
            return parsed ? "on" : "off"
        case "voice-return-triggers":
            let triggers = try parseVoiceReturnTriggers(value)
            store.set(triggers, forKey: UserDefaultsAppRuntimePreferences.voiceReturnTriggersKey)
            store.set(triggers.first, forKey: UserDefaultsAppRuntimePreferences.voiceReturnTriggerKey)
            return displayVoiceReturnTriggers(triggers)
        case "save-transcription-audio":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey)
            return parsed ? "on" : "off"
        case "meeting-audio-retention":
            let retention = try parseMeetingAudioRetention(value)
            UserDefaultsAppRuntimePreferences.saveMeetingAudioRetention(retention, defaults: store)
            return retention.configurationValue
        case "meeting-audio-source":
            let mode = try parseMeetingAudioSourceMode(value)
            store.set(mode.rawValue, forKey: UserDefaultsAppRuntimePreferences.meetingAudioSourceModeKey)
            return mode.configurationValue
        case "prefer-built-in-mic-bluetooth-output":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: UserDefaultsAppRuntimePreferences.preferBuiltInMicWhenBluetoothOutputKey)
            return parsed ? "on" : "off"
        case "save-meeting-audio":
            let parsed = try parseBool(value, key: key)
            UserDefaultsAppRuntimePreferences.saveMeetingAudioRetention(
                parsed ? .keepForever : .deleteImmediately,
                defaults: store
            )
            return parsed ? "on" : "off"
        case "youtube-audio-quality":
            let quality = try parseYouTubeAudioQuality(value)
            store.set(quality.rawValue, forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey)
            return displayYouTubeAudioQuality(quality)
        case "meeting-artifacts-folder":
            let folder = try parseMeetingArtifactsFolder(value)
            if let folder {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: folder, isDirectory: true),
                    withIntermediateDirectories: true
                )
                store.set(folder, forKey: AppPaths.meetingArtifactsFolderKey)
                return folder
            }
            store.removeObject(forKey: AppPaths.meetingArtifactsFolderKey)
            return AppPaths.defaultMeetingRecordingsDir
        case "meeting-hook-enabled":
            let parsed = try parseBool(value, key: key)
            store.set(parsed, forKey: MeetingAutomationHookConfiguration.enabledKey)
            return parsed ? "on" : "off"
        case "meeting-hook-path":
            let path = try parseMeetingHookPath(value)
            if let path {
                guard FileManager.default.isExecutableFile(atPath: path) else {
                    throw ValidationError("Invalid value for meeting-hook-path: '\(value)'. The path must exist and be executable.")
                }
                store.set(path, forKey: MeetingAutomationHookConfiguration.executablePathKey)
                return path
            }
            store.removeObject(forKey: MeetingAutomationHookConfiguration.executablePathKey)
            return "none"
        case "meeting-hook-timeout":
            let timeout = try parseMeetingHookTimeout(value)
            store.set(timeout, forKey: MeetingAutomationHookConfiguration.timeoutSecondsKey)
            return displayTimeout(timeout)
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
            throw ValidationError("Invalid value for speech-engine: '\(value)'. Use parakeet, nemotron, whisper, or cohere.")
        }
        return engine
    }

    /// Accepts the canonical `v3`/`v2`/`unified` ids plus the friendlier
    /// `multilingual`/`english` aliases so users can express intent either way.
    static func parseParakeetModelVariant(_ value: String) throws -> ParakeetModelVariant {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch raw {
        case "v3", "multilingual", "multi":
            return .v3
        case "v2", "english", "english-only", "en":
            return .v2
        case "unified", "english-unified", "unified-offline":
            return .unified
        default:
            throw ValidationError("Invalid value for parakeet-model: '\(value)'. Use v3 (multilingual), v2 (English-only), or unified (English-only with punctuation/capitalization).")
        }
    }

    /// Accepts the canonical tier ids plus the friendlier
    /// `multilingual`/`english` aliases, mirroring `parseParakeetModelVariant`.
    static func parseNemotronModelVariant(_ value: String) throws -> NemotronModelVariant {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch raw {
        case "multilingual-1120ms", "multilingual", "multi":
            return .multilingual1120
        case "english-1120ms", "english", "english-only", "en":
            return .english1120
        default:
            throw ValidationError("Invalid value for nemotron-model: '\(value)'. Use multilingual-1120ms or english-1120ms.")
        }
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

    static func parseNemotronLanguage(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "auto" || lowered == "auto-detect" {
            return nil
        }
        guard let language = SpeechEnginePreference.normalizeNemotronLanguage(trimmed) else {
            throw ValidationError("Invalid value for nemotron-language: '\(value)'. Use auto or a language code such as en-US, ko, or zh-CN.")
        }
        return language
    }

    static func parseCohereLanguage(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let language = SpeechEnginePreference.normalizeCohereLanguage(trimmed) else {
            let supported = CohereTranscribeEngine.supportedLanguages.map(\.code).joined(separator: ", ")
            throw ValidationError("Invalid value for cohere-language: '\(value)'. Use one of: \(supported).")
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

    static func parseMeetingAudioRetention(_ value: String) throws -> MeetingAudioRetention {
        guard let retention = MeetingAudioRetention.parseConfigurationValue(value) else {
            throw ValidationError("Invalid value for meeting-audio-retention: '\(value)'. Use keep-forever, delete-immediately, delete-after-<1-365>-days, or <1-365>d.")
        }
        return retention
    }

    static func parseMeetingAudioSourceMode(_ value: String) throws -> MeetingAudioSourceMode {
        guard let mode = MeetingAudioSourceMode.parseConfigurationValue(value) else {
            throw ValidationError("Invalid value for meeting-audio-source: '\(value)'. Use microphone-and-system, microphone-only, or system-only.")
        }
        return mode
    }

    static func parseVoiceReturnTriggers(_ value: String) throws -> [String] {
        let rawTriggers = value
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        let triggers = VoiceReturnTriggerPhrases.normalized(rawTriggers)
        guard !triggers.isEmpty else {
            throw ValidationError("Invalid value for voice-return-triggers: '\(value)'. Provide at least one trigger phrase.")
        }
        return triggers
    }

    static func displayVoiceReturnTriggers(_ triggers: [String]) -> String {
        triggers.joined(separator: "|")
    }

    static func parseMeetingArtifactsFolder(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "default" || lowered == "reset" {
            return nil
        }
        guard let normalized = AppPaths.normalizedMeetingArtifactsFolder(trimmed),
              (normalized as NSString).isAbsolutePath
        else {
            throw ValidationError("Invalid value for meeting-artifacts-folder: '\(value)'. Use an absolute path, ~/path, or default.")
        }
        return normalized
    }

    static func parseMeetingHookPath(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "none" || lowered == "off" || lowered == "default" || lowered == "reset" {
            return nil
        }
        guard let normalized = MeetingAutomationHookConfiguration.normalizedExecutablePath(trimmed) else {
            throw ValidationError("Invalid value for meeting-hook-path: '\(value)'. Use an absolute executable path, ~/path, or none.")
        }
        return normalized
    }

    static func parseMeetingHookTimeout(_ value: String) throws -> TimeInterval {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(trimmed),
              seconds >= MeetingAutomationHookConfiguration.minimumTimeoutSeconds,
              seconds <= MeetingAutomationHookConfiguration.maximumTimeoutSeconds
        else {
            throw ValidationError("Invalid value for meeting-hook-timeout: '\(value)'. Use seconds from 1 to 300.")
        }
        return seconds
    }

    static func displayTimeout(_ value: TimeInterval) -> String {
        value.rounded(.towardZero) == value ? String(Int(value)) : String(value)
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

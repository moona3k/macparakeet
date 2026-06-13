import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class ConfigCommandTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Isolate each test in a unique UserDefaults suite so we never touch
        // the user's real `com.macparakeet.MacParakeet` plist.
        suiteName = "macparakeet.test.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - read

    func testSupportedKeysIncludeAgentTranscriptionDefaults() {
        XCTAssertEqual(ConfigCommand.supportedKeys, [
            "telemetry",
            "processing-mode",
            "speech-engine",
            "parakeet-model",
            "nemotron-language",
            "whisper-language",
            "speaker-detection",
            "save-transcription-audio",
            "youtube-audio-quality",
            "meeting-artifacts-folder",
            "meeting-hook-enabled",
            "meeting-hook-path",
            "meeting-hook-timeout",
        ])
    }

    func testReadTelemetryDefaultsToOn() throws {
        // Mirror AppPreferences.isTelemetryEnabled: missing key → on.
        let value = try ConfigCommand.read(key: "telemetry", defaults: defaults)
        XCTAssertEqual(value, "on")
    }

    func testReadTelemetryReflectsExplicitFalse() throws {
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertEqual(try ConfigCommand.read(key: "telemetry", defaults: defaults), "off")
    }

    func testReadTelemetryReflectsExplicitTrue() throws {
        defaults.set(true, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertEqual(try ConfigCommand.read(key: "telemetry", defaults: defaults), "on")
    }

    func testReadAgentDefaultsReflectGUIFallbacks() throws {
        XCTAssertEqual(try ConfigCommand.read(key: "processing-mode", defaults: defaults), "raw")
        XCTAssertEqual(try ConfigCommand.read(key: "speech-engine", defaults: defaults), "parakeet")
        XCTAssertEqual(try ConfigCommand.read(key: "parakeet-model", defaults: defaults), "v3")
        XCTAssertEqual(try ConfigCommand.read(key: "nemotron-language", defaults: defaults), "auto")
        XCTAssertEqual(try ConfigCommand.read(key: "whisper-language", defaults: defaults), "auto")
        XCTAssertEqual(try ConfigCommand.read(key: "speaker-detection", defaults: defaults), "off")
        XCTAssertEqual(try ConfigCommand.read(key: "save-transcription-audio", defaults: defaults), "on")
        XCTAssertEqual(try ConfigCommand.read(key: "youtube-audio-quality", defaults: defaults), "m4a")
        XCTAssertEqual(try ConfigCommand.read(key: "meeting-artifacts-folder", defaults: defaults), AppPaths.defaultMeetingRecordingsDir)
        XCTAssertEqual(try ConfigCommand.read(key: "meeting-hook-enabled", defaults: defaults), "off")
        XCTAssertEqual(try ConfigCommand.read(key: "meeting-hook-path", defaults: defaults), "none")
        XCTAssertEqual(try ConfigCommand.read(key: "meeting-hook-timeout", defaults: defaults), "20")
    }

    func testReadCanonicalizesUnderscoreKeys() throws {
        defaults.set(YouTubeAudioQuality.bestAvailable.rawValue, forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey)
        XCTAssertEqual(try ConfigCommand.read(key: "youtube_audio_quality", defaults: defaults), "best-available")
    }

    func testCanonicalKeyNormalizesUnderscoreAliases() throws {
        XCTAssertEqual(try ConfigCommand.canonicalKey(" youtube_audio_quality "), "youtube-audio-quality")
        XCTAssertEqual(try ConfigCommand.canonicalKey("SPEAKER_DETECTION"), "speaker-detection")
    }

    func testReadUnknownKeyThrowsValidationError() {
        // Maps to errorType="validation" / exit code 2 in --json failure envelope.
        XCTAssertThrowsError(try ConfigCommand.read(key: "bogus", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
            XCTAssertTrue("\(error)".contains("bogus"))
        }
    }

    // MARK: - write

    func testWriteTelemetryOffPersists() throws {
        let canonical = try ConfigCommand.write(key: "telemetry", value: "off", defaults: defaults)
        XCTAssertEqual(canonical, "off")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, false)
    }

    func testWriteTelemetryOnPersists() throws {
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        let canonical = try ConfigCommand.write(key: "telemetry", value: "on", defaults: defaults)
        XCTAssertEqual(canonical, "on")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, true)
    }

    func testWriteAgentTranscriptionDefaultsPersist() throws {
        XCTAssertEqual(try ConfigCommand.write(key: "processing-mode", value: "clean", defaults: defaults), "clean")
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey),
            Dictation.ProcessingMode.clean.rawValue
        )

        XCTAssertEqual(try ConfigCommand.write(key: "speech-engine", value: "whisper", defaults: defaults), "whisper")
        XCTAssertEqual(defaults.string(forKey: SpeechEnginePreference.defaultsKey), SpeechEnginePreference.whisper.rawValue)

        XCTAssertEqual(try ConfigCommand.write(key: "speech-engine", value: "nemotron", defaults: defaults), "nemotron")
        XCTAssertEqual(defaults.string(forKey: SpeechEnginePreference.defaultsKey), SpeechEnginePreference.nemotron.rawValue)

        XCTAssertEqual(try ConfigCommand.write(key: "nemotron-language", value: "en_US", defaults: defaults), "en-US")
        XCTAssertEqual(defaults.string(forKey: SpeechEnginePreference.nemotronDefaultLanguageKey), "en-US")

        XCTAssertEqual(try ConfigCommand.write(key: "whisper-language", value: "ko", defaults: defaults), "ko")
        XCTAssertEqual(defaults.string(forKey: SpeechEnginePreference.whisperDefaultLanguageKey), "ko")

        XCTAssertEqual(try ConfigCommand.write(key: "speaker-detection", value: "on", defaults: defaults), "on")
        XCTAssertEqual(defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool, true)

        XCTAssertEqual(try ConfigCommand.write(key: "save-transcription-audio", value: "off", defaults: defaults), "off")
        XCTAssertEqual(defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey) as? Bool, false)

        XCTAssertEqual(try ConfigCommand.write(key: "youtube-audio-quality", value: "best-available", defaults: defaults), "best-available")
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey),
            YouTubeAudioQuality.bestAvailable.rawValue
        )
    }

    func testWriteCanonicalizesUnderscoreKeys() throws {
        XCTAssertEqual(try ConfigCommand.write(key: "speaker_detection", value: "on", defaults: defaults), "on")
        XCTAssertEqual(defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool, true)
    }

    func testWriteMeetingArtifactFolderPersistsAndResets() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-config-artifacts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertEqual(
            try ConfigCommand.write(key: "meeting-artifacts-folder", value: folder.path, defaults: defaults),
            folder.path
        )
        XCTAssertEqual(defaults.string(forKey: AppPaths.meetingArtifactsFolderKey), folder.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try ConfigCommand.read(key: "meeting-artifacts-folder", defaults: defaults), folder.path)

        XCTAssertEqual(
            try ConfigCommand.write(key: "meeting-artifacts-folder", value: "default", defaults: defaults),
            AppPaths.defaultMeetingRecordingsDir
        )
        XCTAssertNil(defaults.string(forKey: AppPaths.meetingArtifactsFolderKey))
    }

    func testMeetingArtifactFolderRejectsRelativePath() {
        XCTAssertThrowsError(
            try ConfigCommand.write(key: "meeting-artifacts-folder", value: "relative/path", defaults: defaults)
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testWriteMeetingHookConfigPersists() throws {
        XCTAssertEqual(try ConfigCommand.write(key: "meeting-hook-enabled", value: "on", defaults: defaults), "on")
        XCTAssertEqual(defaults.object(forKey: MeetingAutomationHookConfiguration.enabledKey) as? Bool, true)

        XCTAssertEqual(try ConfigCommand.write(key: "meeting-hook-timeout", value: "3.5", defaults: defaults), "3.5")
        XCTAssertEqual(defaults.object(forKey: MeetingAutomationHookConfiguration.timeoutSecondsKey) as? Double, 3.5)

        let executable = URL(fileURLWithPath: "/bin/cat")
        XCTAssertEqual(
            try ConfigCommand.write(key: "meeting-hook-path", value: executable.path, defaults: defaults),
            executable.path
        )
        XCTAssertEqual(defaults.string(forKey: MeetingAutomationHookConfiguration.executablePathKey), executable.path)
        XCTAssertEqual(try ConfigCommand.read(key: "meeting-hook-path", defaults: defaults), executable.path)

        XCTAssertEqual(try ConfigCommand.write(key: "meeting-hook-path", value: "none", defaults: defaults), "none")
        XCTAssertNil(defaults.string(forKey: MeetingAutomationHookConfiguration.executablePathKey))
    }

    func testMeetingHookConfigRejectsUnsafeValues() {
        XCTAssertThrowsError(
            try ConfigCommand.write(key: "meeting-hook-path", value: "relative-hook", defaults: defaults)
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }

        XCTAssertThrowsError(
            try ConfigCommand.write(key: "meeting-hook-timeout", value: "0", defaults: defaults)
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testWriteParakeetModelPersistsAndCanonicalizesAliases() throws {
        XCTAssertEqual(try ConfigCommand.write(key: "parakeet-model", value: "v2", defaults: defaults), "v2")
        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .v2)

        // Friendly aliases canonicalize to the v3/v2 ids.
        XCTAssertEqual(try ConfigCommand.write(key: "parakeet-model", value: "english", defaults: defaults), "v2")
        XCTAssertEqual(try ConfigCommand.write(key: "parakeet-model", value: "multilingual", defaults: defaults), "v3")
        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .v3)

        // Underscore-aliased key resolves too.
        XCTAssertEqual(try ConfigCommand.write(key: "parakeet_model", value: "v2", defaults: defaults), "v2")
        XCTAssertEqual(try ConfigCommand.read(key: "parakeet-model", defaults: defaults), "v2")
    }

    func testWriteParakeetModelRejectsInvalidValue() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "parakeet-model", value: "v9", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testWriteWhisperLanguageAutoClearsStoredDefault() throws {
        defaults.set("ko", forKey: SpeechEnginePreference.whisperDefaultLanguageKey)

        XCTAssertEqual(try ConfigCommand.write(key: "whisper-language", value: "auto", defaults: defaults), "auto")
        XCTAssertNil(defaults.string(forKey: SpeechEnginePreference.whisperDefaultLanguageKey))
    }

    func testWriteNemotronLanguageAutoClearsStoredDefault() throws {
        defaults.set("en-US", forKey: SpeechEnginePreference.nemotronDefaultLanguageKey)

        XCTAssertEqual(try ConfigCommand.write(key: "nemotron-language", value: "auto", defaults: defaults), "auto")
        XCTAssertNil(defaults.string(forKey: SpeechEnginePreference.nemotronDefaultLanguageKey))
    }

    func testWriteNemotronLanguageCanonicalizesScriptAndRegion() throws {
        XCTAssertEqual(
            try ConfigCommand.write(key: "nemotron-language", value: "zh_hant_tw", defaults: defaults),
            "zh-Hant-TW"
        )
        XCTAssertEqual(defaults.string(forKey: SpeechEnginePreference.nemotronDefaultLanguageKey), "zh-Hant-TW")
    }

    func testWriteNemotronLanguageRejectsInvalidValue() {
        XCTAssertThrowsError(
            try ConfigCommand.write(key: "nemotron-language", value: "definitely-not-a-language", defaults: defaults)
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertNil(defaults.string(forKey: SpeechEnginePreference.nemotronDefaultLanguageKey))
    }

    func testWriteAcceptsAllBoolSynonyms() throws {
        for (synonym, expectedBool) in [
            ("on", true), ("ON", true), ("true", true), ("yes", true),
            ("1", true), ("enable", true), ("enabled", true),
            ("off", false), ("OFF", false), ("false", false), ("no", false),
            ("0", false), ("disable", false), ("disabled", false)
        ] {
            let canonical = try ConfigCommand.write(key: "telemetry", value: synonym, defaults: defaults)
            XCTAssertEqual(canonical, expectedBool ? "on" : "off",
                           "Synonym '\(synonym)' should canonicalize to \(expectedBool ? "on" : "off")")
            XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, expectedBool)
        }
    }

    func testWriteRejectsInvalidAgentDefaultValues() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "processing-mode", value: "fancy", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try ConfigCommand.write(key: "speech-engine", value: "cloud", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try ConfigCommand.write(key: "youtube-audio-quality", value: "wav", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testWriteRejectsInvalidValueAsValidationError() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "telemetry", value: "maybe", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
            XCTAssertTrue("\(error)".contains("maybe"))
        }
        // Defaults must not have been mutated.
        XCTAssertNil(defaults.object(forKey: AppPreferences.telemetryEnabledKey))
    }

    func testWriteUnknownKeyThrowsValidationError() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "bogus", value: "on", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
        }
    }

    // MARK: - parseBool

    func testParseBoolRejectsEmpty() {
        XCTAssertThrowsError(try ConfigCommand.parseBool("", key: "telemetry")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testParseBoolRejectsWhitespaceOnly() {
        XCTAssertThrowsError(try ConfigCommand.parseBool("   ", key: "telemetry")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testParseBoolTrimsNewlines() throws {
        XCTAssertTrue(try ConfigCommand.parseBool("\n on \n", key: "telemetry"))
        XCTAssertFalse(try ConfigCommand.parseBool("\n off \n", key: "telemetry"))
    }
}

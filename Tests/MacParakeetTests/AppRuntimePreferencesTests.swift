import Foundation
import XCTest

@testable import MacParakeetCore

final class AppRuntimePreferencesTests: XCTestCase {
    private func makePreferences() -> UserDefaultsAppRuntimePreferences {
        UserDefaultsAppRuntimePreferences(
            defaults: UserDefaults(suiteName: "app-runtime-prefs-\(UUID().uuidString)")!
        )
    }

    func testMarkFirstDictationCompletedReturnsTrueOnlyOnFirstTransition() {
        let preferences = makePreferences()
        XCTAssertFalse(preferences.hasCompletedFirstDictation)

        // First call flips the flag and reports the transition so the caller
        // can fire the one-shot activation telemetry event.
        XCTAssertTrue(preferences.markFirstDictationCompleted())
        XCTAssertTrue(preferences.hasCompletedFirstDictation)

        // Every subsequent call is a no-op and reports no transition.
        XCTAssertFalse(preferences.markFirstDictationCompleted())
        XCTAssertFalse(preferences.markFirstDictationCompleted())
        XCTAssertTrue(preferences.hasCompletedFirstDictation)
    }

    func testKeepDictationOnClipboardDefaultsToFalse() {
        let preferences = makePreferences()
        XCTAssertFalse(preferences.shouldKeepDictationOnClipboard)
    }

    func testKeepDictationOnClipboardReadsStoredValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.keepDictationOnClipboardKey)

        let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertTrue(preferences.shouldKeepDictationOnClipboard)
    }

    func testDictationUndoCountdownDefaultsToFiveSeconds() {
        let preferences = makePreferences()
        XCTAssertEqual(preferences.dictationUndoCountdown, .fiveSeconds)
        XCTAssertEqual(preferences.dictationUndoCountdown.seconds, 5)
    }

    func testDictationUndoCountdownRoundTripsStoredValue() {
        for countdown in DictationUndoCountdown.allCases {
            let defaults = UserDefaults(suiteName: "app-runtime-prefs-\(UUID().uuidString)")!
            defaults.set(
                countdown.rawValue,
                forKey: UserDefaultsAppRuntimePreferences.dictationUndoCountdownKey
            )
            XCTAssertEqual(DictationUndoCountdown.current(defaults: defaults), countdown)
        }
    }

    func testDictationUndoCountdownFallsBackForUnknownValue() {
        let defaults = UserDefaults(suiteName: "app-runtime-prefs-\(UUID().uuidString)")!
        defaults.set(
            "not-a-real-value",
            forKey: UserDefaultsAppRuntimePreferences.dictationUndoCountdownKey
        )
        XCTAssertEqual(DictationUndoCountdown.current(defaults: defaults), .fiveSeconds)
    }

    func testDictationUndoCountdownOffMapsToNilSeconds() {
        XCTAssertNil(DictationUndoCountdown.off.seconds)
        XCTAssertEqual(DictationUndoCountdown.oneSecond.seconds, 1)
        XCTAssertEqual(DictationUndoCountdown.fiveSeconds.seconds, 5)
    }

    func testSaveMeetingAudioDefaultsToTrueAndReadsLegacyValueBeforeMigration() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).shouldSaveMeetingAudio)

        let legacySuite = "app-runtime-prefs-\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(false, forKey: UserDefaultsAppRuntimePreferences.saveMeetingAudioKey)

        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: legacyDefaults).shouldSaveMeetingAudio)
    }

    func testMeetingAudioRetentionDefaultsToKeepForeverAndPersistsMigratedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)

        XCTAssertEqual(preferences.meetingAudioRetention, .keepForever)
        XCTAssertTrue(preferences.shouldSaveMeetingAudio)
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.meetingAudioRetentionKey),
            MeetingAudioRetentionMode.keepForever.rawValue
        )
    }

    func testMeetingAudioRetentionMigratesLegacyOffToDeleteImmediately() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.saveMeetingAudioKey)

        let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)

        XCTAssertEqual(preferences.meetingAudioRetention, .deleteImmediately)
        XCTAssertFalse(preferences.shouldSaveMeetingAudio)
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.meetingAudioRetentionKey),
            MeetingAudioRetentionMode.deleteImmediately.rawValue
        )
    }

    func testMeetingAudioRetentionDeleteAfterDaysKeepsFreshAudioCompatibilityView() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaultsAppRuntimePreferences.saveMeetingAudioRetention(.deleteAfterDays(14), defaults: defaults)

        let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(preferences.meetingAudioRetention, .deleteAfterDays(14))
        XCTAssertTrue(preferences.shouldSaveMeetingAudio)
        XCTAssertEqual(defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveMeetingAudioKey) as? Bool, true)
    }

    func testMeetingAudioRetentionPersistsCustomDayCountInRange() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaultsAppRuntimePreferences.saveMeetingAudioRetention(.deleteAfterDays(13), defaults: defaults)

        let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(preferences.meetingAudioRetention, .deleteAfterDays(13))
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.meetingAudioRetentionDeleteAfterDaysKey) as? Int,
            13
        )
    }

    func testMeetingAudioRetentionDefaultsInvalidStoredDayCount() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            MeetingAudioRetentionMode.deleteAfterDays.rawValue,
            forKey: UserDefaultsAppRuntimePreferences.meetingAudioRetentionKey
        )
        defaults.set(366, forKey: UserDefaultsAppRuntimePreferences.meetingAudioRetentionDeleteAfterDaysKey)

        XCTAssertEqual(
            UserDefaultsAppRuntimePreferences(defaults: defaults).meetingAudioRetention,
            .deleteAfterDays(MeetingAudioRetention.defaultDeleteAfterDays)
        )
    }

    func testMeetingAudioRetentionModeDisplayTitlesUseLifecycleCopy() {
        XCTAssertEqual(MeetingAudioRetentionMode.keepForever.displayTitle, "Keep forever")
        XCTAssertEqual(MeetingAudioRetentionMode.deleteAfterDays.displayTitle, "Remove after...")
        XCTAssertEqual(MeetingAudioRetentionMode.deleteImmediately.displayTitle, "Remove audio after transcription")
    }

    func testMeetingAudioSourceModeDefaultsToMicrophoneAndSystemAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).meetingAudioSourceMode, .microphoneAndSystem)

        defaults.set(
            MeetingAudioSourceMode.microphoneOnly.rawValue,
            forKey: UserDefaultsAppRuntimePreferences.meetingAudioSourceModeKey
        )

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).meetingAudioSourceMode, .microphoneOnly)

        defaults.set("not-a-source-mode", forKey: UserDefaultsAppRuntimePreferences.meetingAudioSourceModeKey)

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).meetingAudioSourceMode, .microphoneAndSystem)
    }

    func testMeetingAudioSourceModeCaptureBooleansAndConfigurationParsing() {
        XCTAssertTrue(MeetingAudioSourceMode.microphoneAndSystem.capturesMicrophone)
        XCTAssertTrue(MeetingAudioSourceMode.microphoneAndSystem.capturesSystemAudio)
        XCTAssertTrue(MeetingAudioSourceMode.microphoneOnly.capturesMicrophone)
        XCTAssertFalse(MeetingAudioSourceMode.microphoneOnly.capturesSystemAudio)
        XCTAssertFalse(MeetingAudioSourceMode.systemOnly.capturesMicrophone)
        XCTAssertTrue(MeetingAudioSourceMode.systemOnly.capturesSystemAudio)

        XCTAssertEqual(
            MeetingAudioSourceMode.parseConfigurationValue("microphone-and-system"),
            .microphoneAndSystem
        )
        XCTAssertEqual(
            MeetingAudioSourceMode.parseConfigurationValue("Microphone + system audio"),
            .microphoneAndSystem
        )
        XCTAssertEqual(MeetingAudioSourceMode.parseConfigurationValue("mic"), .microphoneOnly)
        XCTAssertEqual(MeetingAudioSourceMode.parseConfigurationValue("computer audio"), .systemOnly)
        XCTAssertNil(MeetingAudioSourceMode.parseConfigurationValue("echo-cancelled"))
    }

    func testDictationInsertionStyleDefaultsToSentenceAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).dictationInsertionStyle, .sentence)

        defaults.set(
            DictationInsertionStyle.inline.rawValue,
            forKey: UserDefaultsAppRuntimePreferences.dictationInsertionStyleKey
        )

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).dictationInsertionStyle, .inline)

        defaults.set("not-a-style", forKey: UserDefaultsAppRuntimePreferences.dictationInsertionStyleKey)

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).dictationInsertionStyle, .sentence)
    }

    func testAppAppearanceModeDefaultsToSystemAndIgnoresInvalidValues() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppAppearanceMode.current(defaults: defaults), .system)

        defaults.set("not-a-mode", forKey: AppPreferences.appearanceModeKey)

        XCTAssertEqual(AppAppearanceMode.current(defaults: defaults), .system)
    }

    func testAppAppearanceModeReadsStoredValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(AppAppearanceMode.dark.rawValue, forKey: AppPreferences.appearanceModeKey)

        XCTAssertEqual(AppPreferences.appearanceMode(defaults: defaults), .dark)
    }

    func testFirstDictationFlagPersistsAcrossInstances() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertTrue(first.markFirstDictationCompleted())

        // A fresh instance over the same store already sees the flag set, so a
        // user who has dictated before never re-emits the activation event.
        let second = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertTrue(second.hasCompletedFirstDictation)
        XCTAssertFalse(second.markFirstDictationCompleted())
    }

    func testPauseMediaDuringDictationDefaultsToFalseAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).pauseMediaDuringDictation)

        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.pauseMediaDuringDictationKey)

        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).pauseMediaDuringDictation)
    }

    func testInstantDictationDefaultsToFalseAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).instantDictationEnabled)

        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.instantDictationEnabledKey)

        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).instantDictationEnabled)
    }

    func testLiveDictationPreviewDefaultsToTrueAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).showLiveDictationPreview)

        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.showLiveDictationPreviewKey)

        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).showLiveDictationPreview)
    }

    func testDictationPreviewTextSizeDefaultsToMediumAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).dictationPreviewTextSize, .medium)

        defaults.set(
            DictationPreviewTextSize.large.rawValue,
            forKey: UserDefaultsAppRuntimePreferences.dictationPreviewTextSizeKey
        )

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).dictationPreviewTextSize, .large)
    }

    func testDictationPreviewTextSizeFallsBackToMediumOnUnknownRawValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("gigantic", forKey: UserDefaultsAppRuntimePreferences.dictationPreviewTextSizeKey)

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).dictationPreviewTextSize, .medium)
    }

    func testAIFormatterEnabledForDictationDefaultsToFalseAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).aiFormatterEnabledForDictation)

        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey)

        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).aiFormatterEnabledForDictation)
    }

    func testAIFormatterEnabledForTranscriptionsDefaultsToTrueAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).aiFormatterEnabledForTranscriptions)

        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForTranscriptionsKey)

        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).aiFormatterEnabledForTranscriptions)
    }

    func testTranscriptAIContextModeDefaultsToRichAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).transcriptAIContextMode, .richTranscript)

        defaults.set(
            TranscriptAIContextMode.plainTranscript.rawValue,
            forKey: UserDefaultsAppRuntimePreferences.transcriptAIContextModeKey
        )

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).transcriptAIContextMode, .plainTranscript)

        defaults.set("not-a-mode", forKey: UserDefaultsAppRuntimePreferences.transcriptAIContextModeKey)

        XCTAssertEqual(UserDefaultsAppRuntimePreferences(defaults: defaults).transcriptAIContextMode, .richTranscript)
    }

    /// Models the gate the composition root installs on the dictation path: the
    /// AI Formatter runs on dictation only when the global switch AND the
    /// dictation-specific switch are both on.
    func testDictationFormatterGateIsConjunctionOfGlobalAndDictationFlags() {
        func dictationGate(global: Bool, dictation: Bool) -> Bool {
            let suite = "app-runtime-prefs-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(global, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
            defaults.set(dictation, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey)
            let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
            return prefs.aiFormatterEnabled && prefs.aiFormatterEnabledForDictation
        }

        XCTAssertTrue(dictationGate(global: true, dictation: true))
        XCTAssertFalse(dictationGate(global: true, dictation: false))
        XCTAssertFalse(dictationGate(global: false, dictation: true))
        XCTAssertFalse(dictationGate(global: false, dictation: false))
    }

    /// Models the gate the composition root installs on the file/meeting
    /// transcription path: the AI Formatter runs only when the global switch
    /// AND the transcripts-specific switch are both on. With the transcripts
    /// key unset the gate follows the global switch alone (pre-#493 behavior).
    func testTranscriptionFormatterGateIsConjunctionOfGlobalAndTranscriptsFlags() {
        func transcriptionGate(global: Bool, transcripts: Bool?) -> Bool {
            let suite = "app-runtime-prefs-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(global, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
            if let transcripts {
                defaults.set(transcripts, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForTranscriptionsKey)
            }
            let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
            return prefs.aiFormatterEnabled && prefs.aiFormatterEnabledForTranscriptions
        }

        XCTAssertTrue(transcriptionGate(global: true, transcripts: nil))
        XCTAssertTrue(transcriptionGate(global: true, transcripts: true))
        XCTAssertFalse(transcriptionGate(global: true, transcripts: false))
        XCTAssertFalse(transcriptionGate(global: false, transcripts: nil))
        XCTAssertFalse(transcriptionGate(global: false, transcripts: true))
    }
}

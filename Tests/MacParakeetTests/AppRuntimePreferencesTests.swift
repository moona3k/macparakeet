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
}

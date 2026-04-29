import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class SettingsStatusRulesTests: XCTestCase {
    func testLocalModelsDoesNotShowReadyWhenInactiveWhisperIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .ready,
            whisper: .notDownloaded,
            activeEngine: .parakeet
        )

        XCTAssertNil(status)
    }

    func testLocalModelsShowsReadyOnlyWhenBothEnginesAreAvailable() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            whisper: .notLoaded,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testLocalModelsRecommendsDownloadWhenActiveEngineIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            whisper: .notDownloaded,
            activeEngine: .whisper
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Download recommended"))
    }

    func testLocalModelsRequiresActionWhenEitherEngineFailed() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .ready,
            whisper: .failed,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Action needed"))
    }

    func testMeetingRecordingRequiresScreenRecordingPermission() {
        let status = SettingsStatusRules.meetingRecordingCardStatus(
            meetingRecordingEnabled: true,
            screenRecordingGranted: false
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Permission required"))
    }

    func testPermissionsRequiresActionWhenScreenRecordingMissingForMeetings() {
        let status = SettingsStatusRules.permissionsCardStatus(
            meetingRecordingEnabled: true,
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Action required"))
    }
}

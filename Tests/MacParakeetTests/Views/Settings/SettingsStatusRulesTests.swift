import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class SettingsStatusRulesTests: XCTestCase {
    func testLocalModelsDoesNotShowReadyWhenInactiveWhisperIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .ready,
            nemotron: .notLoaded,
            whisper: .notDownloaded,
            activeEngine: .parakeet
        )

        XCTAssertNil(status)
    }

    func testLocalModelsShowsReadyOnlyWhenAllEnginesAreAvailable() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notLoaded,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testLocalModelsShowsReadyWhenOptionalNemotronIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notDownloaded,
            whisper: .notLoaded,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testLocalModelsRecommendsDownloadWhenActiveEngineIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notDownloaded,
            activeEngine: .whisper
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Download recommended"))
    }

    func testLocalModelsShowsPreparingWhenActiveEngineIsPreparing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .preparing,
            activeEngine: .whisper
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Preparing"))
    }

    func testLocalModelsRequiresActionWhenEitherEngineFailed() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .ready,
            nemotron: .notLoaded,
            whisper: .failed,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Action needed"))
    }

    func testLocalModelsRecommendsDownloadWhenActiveNemotronIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notDownloaded,
            whisper: .notLoaded,
            activeEngine: .nemotron
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Download recommended"))
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

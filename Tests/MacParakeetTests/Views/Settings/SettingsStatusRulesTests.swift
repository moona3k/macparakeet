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

    func testMeetingRecordingRequiresScreenRecordingPermissionForSystemAudioModes() {
        let status = SettingsStatusRules.meetingRecordingCardStatus(
            meetingRecordingEnabled: true,
            screenRecordingGranted: false,
            meetingAudioSourceMode: .microphoneAndSystem
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Permission required"))
    }

    func testMeetingRecordingReadyWithoutScreenRecordingForMicrophoneOnlyMode() {
        let status = SettingsStatusRules.meetingRecordingCardStatus(
            meetingRecordingEnabled: true,
            screenRecordingGranted: false,
            meetingAudioSourceMode: .microphoneOnly
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testPermissionsRequiresActionWhenScreenRecordingMissingForSystemAudioModes() {
        let status = SettingsStatusRules.permissionsCardStatus(
            meetingRecordingEnabled: true,
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingAudioSourceMode: .microphoneAndSystem
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Action required"))
    }

    func testPermissionsAllGrantedWithoutScreenRecordingForMicrophoneOnlyMode() {
        let status = SettingsStatusRules.permissionsCardStatus(
            meetingRecordingEnabled: true,
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingAudioSourceMode: .microphoneOnly
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }
}

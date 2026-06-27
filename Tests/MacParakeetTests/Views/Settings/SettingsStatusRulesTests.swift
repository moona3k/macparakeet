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
            cohere: .ready,
            activeEngine: .parakeet
        )

        XCTAssertNil(status)
    }

    func testLocalModelsShowsReadyOnlyWhenAllEnginesAreAvailable() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notLoaded,
            cohere: .ready,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testLocalModelsShowsReadyWhenOptionalNemotronIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notDownloaded,
            whisper: .notLoaded,
            cohere: .ready,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testLocalModelsRecommendsDownloadWhenActiveEngineIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notDownloaded,
            cohere: .ready,
            activeEngine: .whisper
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Download recommended"))
    }

    func testLocalModelsShowsPreparingWhenActiveEngineIsPreparing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .preparing,
            cohere: .ready,
            activeEngine: .whisper
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Preparing"))
    }

    func testLocalModelsRequiresActionWhenEitherEngineFailed() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .ready,
            nemotron: .notLoaded,
            whisper: .failed,
            cohere: .ready,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Action needed"))
    }

    func testLocalModelsRecommendsDownloadWhenActiveNemotronIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notDownloaded,
            whisper: .notLoaded,
            cohere: .ready,
            activeEngine: .nemotron
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Download recommended"))
    }

    func testLocalModelsRecommendsDownloadWhenActiveCohereIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notLoaded,
            cohere: .notDownloaded,
            activeEngine: .cohere
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Download recommended"))
    }

    func testLocalModelsShowsReadyWhenOptionalCohereIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notLoaded,
            cohere: .notDownloaded,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testLocalModelsShowsPreparingWhenActiveCohereIsPreparing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notLoaded,
            cohere: .preparing,
            activeEngine: .cohere
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Preparing"))
    }

    func testLocalModelsIgnoresInactiveCohereFailureWhenCohereIsHidden() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notLoaded,
            cohere: .failed,
            cohereEnabled: false,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testLocalModelsStillRequiresActionForActiveCohereFailureWhenCohereIsHidden() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            nemotron: .notLoaded,
            whisper: .notLoaded,
            cohere: .failed,
            cohereEnabled: false,
            activeEngine: .cohere
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Action needed"))
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

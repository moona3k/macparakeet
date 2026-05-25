import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class DictationFlowCoordinatorTests: XCTestCase {
    func testSuccessfulMicPermissionRequestDismissesStaleStartFailure() async throws {
        let harness = try await makeMicPermissionHarness(
            microphonePermission: .notDetermined,
            requestMicResult: true
        )

        harness.coordinator.startDictation(mode: .persistent, trigger: .hotkey)

        let requestedPermission = await waitUntil {
            harness.permissionService.requestMicrophonePermissionCallCount == 1
        }
        XCTAssertTrue(requestedPermission)
        XCTAssertEqual(harness.permissionService.microphonePermission, .granted)
        XCTAssertEqual(harness.permissionService.openMicrophoneSettingsCallCount, 0)
        let startCaptureCalled = await harness.audio.startCaptureCalled
        XCTAssertTrue(startCaptureCalled)

        let dismissedStaleError = await waitUntil {
            harness.coordinator.overlayStateForTesting == nil
        }
        XCTAssertTrue(dismissedStaleError)
    }

    func testMenuBarPreferenceMatchesStateMachineIntent() {
        XCTAssertEqual(DictationFlowCoordinator.menuBarPreference(for: .startingService(mode: .persistent)), .recording)
        XCTAssertEqual(DictationFlowCoordinator.menuBarPreference(for: .recording(mode: .holdToTalk)), .recording)
        XCTAssertEqual(DictationFlowCoordinator.menuBarPreference(for: .pendingStop(mode: .persistent)), .recording)
        XCTAssertEqual(DictationFlowCoordinator.menuBarPreference(for: .processing), .processing)
    }

    func testMenuBarPreferenceIsNilOutsideActiveStates() {
        let states: [DictationFlowState] = [
            .idle,
            .ready,
            .checkingEntitlements(mode: .persistent),
            .cancelCountdown,
            .finishing(outcome: .success),
            .finishing(outcome: .noSpeech),
            .finishing(outcome: .error("boom")),
            .finishing(outcome: .pasteFailedCopied("Copied to clipboard. Press Cmd+V.")),
        ]

        for state in states {
            XCTAssertNil(DictationFlowCoordinator.menuBarPreference(for: state), "Expected nil for \(state)")
        }
    }

    func testIsCapturingAudioTrueForCaptureAndProcessingStates() {
        XCTAssertTrue(DictationFlowCoordinator.isCapturingAudio(for: .startingService(mode: .persistent)))
        XCTAssertTrue(DictationFlowCoordinator.isCapturingAudio(for: .recording(mode: .holdToTalk)))
        XCTAssertTrue(DictationFlowCoordinator.isCapturingAudio(for: .pendingStop(mode: .persistent)))
        XCTAssertTrue(DictationFlowCoordinator.isCapturingAudio(for: .processing))
    }

    func testIsCapturingAudioFalseForNonCaptureStatesIncludingFinishing() {
        let states: [DictationFlowState] = [
            .idle,
            .ready,
            .checkingEntitlements(mode: .persistent),
            .cancelCountdown,
            .finishing(outcome: .success),
            .finishing(outcome: .noSpeech),
            .finishing(outcome: .error("boom")),
            .finishing(outcome: .pasteFailedCopied("Copied to clipboard. Press Cmd+V.")),
        ]

        for state in states {
            XCTAssertFalse(DictationFlowCoordinator.isCapturingAudio(for: state), "Expected false for \(state)")
        }
    }

    func testMediaPauseCaptureActiveExcludesProcessing() {
        XCTAssertTrue(DictationFlowCoordinator.mediaPauseCaptureActive(for: .startingService(mode: .persistent)))
        XCTAssertTrue(DictationFlowCoordinator.mediaPauseCaptureActive(for: .recording(mode: .holdToTalk)))
        XCTAssertTrue(DictationFlowCoordinator.mediaPauseCaptureActive(for: .pendingStop(mode: .persistent)))

        let states: [DictationFlowState] = [
            .idle,
            .ready,
            .checkingEntitlements(mode: .persistent),
            .processing,
            .cancelCountdown,
            .finishing(outcome: .success),
            .finishing(outcome: .noSpeech),
            .finishing(outcome: .error("boom")),
            .finishing(outcome: .pasteFailedCopied("Copied to clipboard. Press Cmd+V.")),
        ]

        for state in states {
            XCTAssertFalse(DictationFlowCoordinator.mediaPauseCaptureActive(for: state), "Expected false for \(state)")
        }
    }

    func testPasteFailureMessagePreservesAccessibilityCauseWhenCopied() {
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.accessibilityPermissionRequired,
            copiedToClipboard: true
        )

        XCTAssertEqual(
            message,
            "Accessibility permission is required for auto-paste. Copied to clipboard. Press Cmd+V."
        )
    }

    func testPasteFailureMessagePreservesAccessibilityCauseWhenNotCopied() {
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.accessibilityPermissionRequired,
            copiedToClipboard: false
        )

        XCTAssertEqual(
            message,
            "Accessibility permission is required for auto-paste, but the clipboard could not be updated."
        )
    }

    func testPasteFailureMessageReportsClipboardWriteFailureWhenNotCopied() {
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.pasteboardWriteFailed,
            copiedToClipboard: false
        )

        XCTAssertEqual(message, "Paste failed and the clipboard could not be updated.")
    }

    func testPasteFailureMessageStaysGenericWhenCopiedWithoutAccessibilityCause() {
        // A non-permission paste failure (e.g. CGEvent infrastructure) that still
        // landed on the clipboard must keep the generic copy - it must NOT claim
        // an Accessibility cause it cannot attribute.
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.eventSourceUnavailable,
            copiedToClipboard: true
        )

        XCTAssertEqual(message, "Copied to clipboard. Press Cmd+V.")
    }

    func testPasteFailureMessageDoesNotSuggestPasteWhenNotCopied() {
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.eventCreationFailed,
            copiedToClipboard: false
        )

        XCTAssertEqual(
            message,
            "Paste failed and the clipboard could not be updated."
        )
    }

    func testCommandFailureBucketSplitsClipboardPermissionFailure() {
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: ClipboardServiceError.accessibilityPermissionRequired),
            "paste_accessibility_permission"
        )
    }

    func testCommandFailureBucketSplitsClipboardInfrastructureFailures() {
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: ClipboardServiceError.eventSourceUnavailable),
            "paste_event_source_unavailable"
        )
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: ClipboardServiceError.eventCreationFailed),
            "paste_event_creation_failed"
        )
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: ClipboardServiceError.pasteboardWriteFailed),
            "pasteboard_write_failed"
        )
    }

    private func makeMicPermissionHarness(
        microphonePermission: PermissionStatus,
        requestMicResult: Bool
    ) async throws -> MicPermissionHarness {
        let dbManager = try DatabaseManager()
        let audio = MockAudioProcessor()
        await audio.configureCaptureError(AudioProcessorError.microphonePermissionDenied)
        let stt = MockSTTClient()
        let repo = DictationRepository(dbQueue: dbManager.dbQueue)
        let service = DictationService(
            audioProcessor: audio,
            sttTranscriber: stt,
            dictationRepo: repo
        )

        let settingsDefaults = UserDefaults(suiteName: "mic-permission-settings-\(UUID().uuidString)")!
        settingsDefaults.set(false, forKey: UserDefaultsAppRuntimePreferences.showIdlePillKey)
        let settings = SettingsViewModel(defaults: settingsDefaults)

        let preferences = UserDefaultsAppRuntimePreferences(
            defaults: UserDefaults(suiteName: "mic-permission-preferences-\(UUID().uuidString)")!
        )
        let entitlements = EntitlementsService(
            config: LicensingConfig(checkoutURL: nil, expectedVariantID: nil),
            store: InMemoryKeyValueStore(),
            api: StubLicenseAPI()
        )
        let permissionService = MockPermissionService()
        permissionService.microphonePermission = microphonePermission
        permissionService.requestMicResult = requestMicResult

        let coordinator = DictationFlowCoordinator(
            dictationService: service,
            clipboardService: MockClipboardService(),
            entitlementsService: entitlements,
            dictationRepo: repo,
            settingsViewModel: settings,
            sttRuntime: AlwaysReadySTTReadinessChecker(),
            runtimePreferences: preferences,
            permissionService: permissionService,
            overlayControllerFactory: { MicPermissionSpyDictationOverlayController(viewModel: $0) },
            onMenuBarIconUpdate: { _ in },
            onHistoryReload: {},
            onPresentEntitlementsAlert: { _ in }
        )

        return MicPermissionHarness(
            coordinator: coordinator,
            audio: audio,
            permissionService: permissionService
        )
    }

    private func waitUntil(
        timeoutMs: UInt64 = 1200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private struct MicPermissionHarness {
        let coordinator: DictationFlowCoordinator
        let audio: MockAudioProcessor
        let permissionService: MockPermissionService
    }
}

private struct AlwaysReadySTTReadinessChecker: DictationSTTReadinessChecking {
    func isReady() async -> Bool { true }
}

@MainActor
private final class MicPermissionSpyDictationOverlayController: DictationOverlayControlling {
    let viewModel: DictationOverlayViewModel

    init(viewModel: DictationOverlayViewModel) {
        self.viewModel = viewModel
    }

    func show() {}

    func hide() {}

    func resignKeyWindow() {}
}

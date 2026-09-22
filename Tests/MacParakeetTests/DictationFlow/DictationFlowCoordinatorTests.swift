import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class DictationFlowCoordinatorTests: XCTestCase {
    func testCodexAutoSubmitEligibilityIsExactAndFailClosed() {
        let codexContext = AppPromptContext(bundleIdentifier: "COM.OPENAI.CODEX")
        let otherContext = AppPromptContext(bundleIdentifier: "com.apple.TextEdit")

        XCTAssertTrue(DictationFlowCoordinator.shouldAutoSubmitCodexDictation(
            enabled: true,
            transcriptHasText: true,
            requestedAction: nil,
            focusedContext: codexContext
        ))
        XCTAssertFalse(DictationFlowCoordinator.shouldAutoSubmitCodexDictation(
            enabled: false,
            transcriptHasText: true,
            requestedAction: nil,
            focusedContext: codexContext
        ))
        XCTAssertFalse(DictationFlowCoordinator.shouldAutoSubmitCodexDictation(
            enabled: true,
            transcriptHasText: false,
            requestedAction: nil,
            focusedContext: codexContext
        ))
        XCTAssertFalse(DictationFlowCoordinator.shouldAutoSubmitCodexDictation(
            enabled: true,
            transcriptHasText: true,
            requestedAction: .returnKey,
            focusedContext: codexContext
        ))
        XCTAssertFalse(DictationFlowCoordinator.shouldAutoSubmitCodexDictation(
            enabled: true,
            transcriptHasText: true,
            requestedAction: nil,
            focusedContext: otherContext
        ))
        XCTAssertFalse(DictationFlowCoordinator.shouldAutoSubmitCodexDictation(
            enabled: true,
            transcriptHasText: true,
            requestedAction: nil,
            focusedContext: nil
        ))
    }

    func testCompletedCodexDictationPastesWithoutTrailingSpaceAndRequestsGuardedReturn() async throws {
        let harness = try await makeRecordingHarness(
            autoSubmitCodexDictation: true,
            focusedContext: AppPromptContext(bundleIdentifier: "com.openai.codex", displayName: "Codex")
        )
        await harness.stt.configureSequence(results: [STTResult(text: "send this to Forge")])

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)
        let started = await waitUntil {
            self.isFlowRecording(harness.coordinator.flowStateForTesting)
        }
        XCTAssertTrue(started)

        harness.coordinator.stopDictation()
        let submitted = await waitUntilAsync {
            let snapshot = await harness.clipboard.snapshot()
            return snapshot.lastPostPasteAction == .returnKey
                && snapshot.lastRequiredFrontmostBundleIdentifier == DictationFlowCoordinator.codexBundleIdentifier
        }

        XCTAssertTrue(submitted)
        let snapshot = await harness.clipboard.snapshot()
        XCTAssertEqual(snapshot.lastPastedText, "send this to Forge")
        XCTAssertEqual(snapshot.lastPostPasteAction, .returnKey)
        XCTAssertEqual(snapshot.lastRequiredFrontmostBundleIdentifier, "com.openai.codex")
    }

    func testCodexAutoSubmitFocusRejectionCopiesTranscriptAndReportsWhy() async throws {
        let harness = try await makeRecordingHarness(
            autoSubmitCodexDictation: true,
            focusedContext: AppPromptContext(bundleIdentifier: "com.openai.codex", displayName: "Codex")
        )
        await harness.stt.configureSequence(results: [STTResult(text: "keep this safe")])
        await harness.clipboard.setPasteError(
            ClipboardServiceError.requiredFrontmostApplicationUnavailable
        )

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)
        let started = await waitUntil {
            self.isFlowRecording(harness.coordinator.flowStateForTesting)
        }
        XCTAssertTrue(started)

        harness.coordinator.stopDictation()
        let reported = await waitUntil {
            harness.coordinator.flowStateForTesting == .finishing(
                outcome: .pasteFailedCopied(
                    "Codex lost focus. Copied to clipboard. Return to Codex and press Cmd+V."
                )
            )
        }

        XCTAssertTrue(reported)
        let snapshot = await harness.clipboard.snapshot()
        XCTAssertEqual(snapshot.lastCopiedText, "keep this safe")
        XCTAssertEqual(snapshot.lastPostPasteAction, .returnKey)
        XCTAssertEqual(snapshot.lastRequiredFrontmostBundleIdentifier, "com.openai.codex")
    }

    func testCodexAutoSubmitFocusLossAfterPasteSuppressesReturnAndReportsPartialCompletion() async throws {
        let harness = try await makeRecordingHarness(
            autoSubmitCodexDictation: true,
            focusedContext: AppPromptContext(bundleIdentifier: "com.openai.codex", displayName: "Codex")
        )
        await harness.stt.configureSequence(results: [STTResult(text: "do not submit this elsewhere")])
        await harness.clipboard.setPostPasteActionFired(false)

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)
        let started = await waitUntil {
            self.isFlowRecording(harness.coordinator.flowStateForTesting)
        }
        XCTAssertTrue(started)

        harness.coordinator.stopDictation()
        let reported = await waitUntil {
            harness.coordinator.flowStateForTesting == .finishing(
                outcome: .postPasteActionSuppressed(
                    "Dictation was pasted, but Return was not sent. Keep Codex frontmost and press Return."
                )
            )
        }

        XCTAssertTrue(reported)
        let snapshot = await harness.clipboard.snapshot()
        XCTAssertEqual(snapshot.lastPastedText, "do not submit this elsewhere")
        XCTAssertNil(snapshot.lastCopiedText)
        XCTAssertEqual(snapshot.lastPostPasteAction, .returnKey)
        XCTAssertEqual(snapshot.lastRequiredFrontmostBundleIdentifier, "com.openai.codex")
    }

    func testDisabledCodexAutoSubmitUsesOrdinaryPasteWithoutReturn() async throws {
        let harness = try await makeRecordingHarness(
            autoSubmitCodexDictation: false,
            focusedContext: AppPromptContext(bundleIdentifier: "com.openai.codex", displayName: "Codex")
        )
        await harness.stt.configureSequence(results: [STTResult(text: "draft only")])

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)
        let started = await waitUntil {
            self.isFlowRecording(harness.coordinator.flowStateForTesting)
        }
        XCTAssertTrue(started)
        harness.coordinator.stopDictation()

        let pasted = await waitUntilAsync {
            let snapshot = await harness.clipboard.snapshot()
            return snapshot.lastPastedText == "draft only "
        }
        XCTAssertTrue(pasted)
        let snapshot = await harness.clipboard.snapshot()
        XCTAssertNil(snapshot.lastPostPasteAction)
        XCTAssertNil(snapshot.lastRequiredFrontmostBundleIdentifier)
    }

    func testEnabledCodexAutoSubmitDoesNotSubmitIntoAnotherApplication() async throws {
        let harness = try await makeRecordingHarness(
            autoSubmitCodexDictation: true,
            focusedContext: AppPromptContext(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit")
        )
        await harness.stt.configureSequence(results: [STTResult(text: "paste elsewhere")])

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)
        let started = await waitUntil {
            self.isFlowRecording(harness.coordinator.flowStateForTesting)
        }
        XCTAssertTrue(started)
        harness.coordinator.stopDictation()

        let pasted = await waitUntilAsync {
            let snapshot = await harness.clipboard.snapshot()
            return snapshot.lastPastedText == "paste elsewhere "
        }
        XCTAssertTrue(pasted)
        let snapshot = await harness.clipboard.snapshot()
        XCTAssertNil(snapshot.lastPostPasteAction)
        XCTAssertNil(snapshot.lastRequiredFrontmostBundleIdentifier)
    }

    func testVoiceControlCannotAcquireDuringDictationCancelUndoWindow() async throws {
        let arbiter = GUIMutationArbiter()
        let harness = try await makeRecordingHarness(mutationArbiter: arbiter)
        harness.coordinator.startDictation(mode: .persistent)
        let started = await waitUntil { self.isFlowRecording(harness.coordinator.flowStateForTesting) }
        XCTAssertTrue(started)
        XCTAssertNil(arbiter.acquire(.voiceControl))
        harness.coordinator.cancelDictation()
        XCTAssertEqual(harness.coordinator.flowStateForTesting, .cancelCountdown)
        XCTAssertNil(arbiter.acquire(.voiceControl), "Undo can still resume this dictation")
        harness.coordinator.cancelDictation()
        XCTAssertEqual(harness.coordinator.flowStateForTesting, .idle)
        XCTAssertNotNil(arbiter.acquire(.voiceControl))
    }

    func testPillStartedPersistentRecordingSyncsFnHotkeyToStop() async throws {
        let harness = try await makeRecordingHarness()
        let fnManager = HotkeyManager(trigger: .fn)
        // Isolate from the host keyboard and prove a Caps Lock latch (key 57)
        // does not contaminate Fn-stop after a pill-started recording. Fn press
        // reconciles CGEventSource keyState; an unstubbed leftover ordinary
        // key would treat the stop gesture as contaminated and return [].
        fnManager.setPhysicalKeyStateProviderForTesting { $0 == 57 }
        harness.coordinator.hotkeyManagers = [fnManager]

        harness.coordinator.startDictation(mode: .persistent, trigger: .pillClick)

        let started = await waitUntil { self.isFlowRecording(harness.coordinator.flowStateForTesting) }
        XCTAssertTrue(started)
        XCTAssertEqual(
            fnManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [.stopRecording]
        )

        harness.coordinator.cancelDictation()
    }

    func testPersistentBackToBackDictationsPasteJustCompletedTranscript() async throws {
        let harness = try await makeRecordingHarness()
        await harness.stt.configureSequence(results: [
            STTResult(text: "first dictated message"),
            STTResult(text: "second dictated message"),
        ])

        harness.coordinator.startDictation(mode: .persistent, trigger: .hotkey)
        let firstStarted = await waitUntil { self.isFlowRecording(harness.coordinator.flowStateForTesting) }
        XCTAssertTrue(firstStarted)

        harness.coordinator.stopDictation()
        let firstPasted = await waitUntilAsync {
            let snapshot = await harness.clipboard.snapshot()
            return snapshot.pastedTexts.count == 1 && harness.coordinator.flowStateForTesting == .idle
        }
        XCTAssertTrue(firstPasted)
        XCTAssertEqual(harness.coordinator.flowStateForTesting, .idle)

        harness.coordinator.startDictation(mode: .persistent, trigger: .hotkey)
        let secondStarted = await waitUntil { self.isFlowRecording(harness.coordinator.flowStateForTesting) }
        XCTAssertTrue(secondStarted)

        harness.coordinator.stopDictation()
        let secondPasted = await waitUntilAsync {
            let snapshot = await harness.clipboard.snapshot()
            return snapshot.pastedTexts.count == 2 && harness.coordinator.flowStateForTesting == .idle
        }
        XCTAssertTrue(secondPasted)

        let clipboardSnapshot = await harness.clipboard.snapshot()
        XCTAssertEqual(
            clipboardSnapshot.pastedTexts,
            ["first dictated message ", "second dictated message "]
        )
        XCTAssertEqual(clipboardSnapshot.lastPastedText, "second dictated message ")

        let savedTranscripts = try harness.repo.fetchAll(limit: nil).map(\.rawTranscript)
        XCTAssertEqual(savedTranscripts.count, 2)
        XCTAssertTrue(savedTranscripts.contains("first dictated message"))
        XCTAssertTrue(savedTranscripts.contains("second dictated message"))
    }

    func testSuccessDwellRestartDoesNotCancelCompletedPaste() async throws {
        let harness = try await makeRecordingHarness()
        await harness.stt.configureSequence(results: [
            STTResult(text: "first delayed paste"),
            STTResult(text: "second dictation"),
        ])
        await harness.clipboard.setPasteDelayMs(100)

        harness.coordinator.startDictation(mode: .persistent, trigger: .hotkey)
        let firstStarted = await waitUntil { self.isFlowRecording(harness.coordinator.flowStateForTesting) }
        XCTAssertTrue(firstStarted)

        harness.coordinator.stopDictation()
        let firstSuccessVisible = await waitUntil {
            if case .success = harness.coordinator.overlayStateForTesting { return true }
            return false
        }
        XCTAssertTrue(firstSuccessVisible)

        harness.coordinator.startDictation(mode: .persistent, trigger: .hotkey)
        let secondStarted = await waitUntil { self.isFlowRecording(harness.coordinator.flowStateForTesting) }
        XCTAssertTrue(secondStarted)

        harness.coordinator.stopDictation()
        let bothPasted = await waitUntilAsync {
            let snapshot = await harness.clipboard.snapshot()
            return snapshot.pastedTexts.count == 2
        }
        XCTAssertTrue(bothPasted)

        let clipboardSnapshot = await harness.clipboard.snapshot()
        XCTAssertEqual(
            clipboardSnapshot.pastedTexts,
            ["first delayed paste ", "second dictation "]
        )
    }

    func testSuccessfulMicPermissionRequestContinuesIntoCapture() async throws {
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

        let started = await waitUntil { self.isFlowRecording(harness.coordinator.flowStateForTesting) }
        XCTAssertTrue(started)
        let startCaptureCalled = await harness.audio.startCaptureCalled
        XCTAssertTrue(startCaptureCalled)
        if case .error = harness.coordinator.overlayStateForTesting {
            XCTFail("Granting the microphone on first press should start capture, not show a start-failure overlay")
        }
    }

    func testHoldToTalkMicGrantDoesNotStartCapture() async throws {
        let harness = try await makeMicPermissionHarness(
            microphonePermission: .notDetermined,
            requestMicResult: true
        )

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)

        let requestedPermission = await waitUntil {
            harness.permissionService.requestMicrophonePermissionCallCount == 1
        }
        XCTAssertTrue(requestedPermission)
        XCTAssertEqual(harness.permissionService.microphonePermission, .granted)

        let returnedToIdle = await waitUntil {
            harness.coordinator.flowStateForTesting == .idle
        }
        XCTAssertTrue(returnedToIdle)
        let startCaptureCalled = await harness.audio.startCaptureCalled
        XCTAssertFalse(
            startCaptureCalled,
            "The system mic sheet interrupts a hold; capture must wait for the next hold"
        )
        if case .error = harness.coordinator.overlayStateForTesting {
            XCTFail("A successful hold-to-talk grant should not show a start-failure overlay")
        }
    }

    func testHoldToTalkStartsCaptureWhenMicrophoneAlreadyGranted() async throws {
        let harness = try await makeMicPermissionHarness(
            microphonePermission: .granted,
            requestMicResult: true
        )

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)

        let started = await waitUntil { self.isFlowRecording(harness.coordinator.flowStateForTesting) }
        XCTAssertTrue(
            started,
            "Hold-to-talk with an already-granted mic must start capture on this hold"
        )
        XCTAssertEqual(harness.permissionService.requestMicrophonePermissionCallCount, 0)
        let startCaptureCalled = await harness.audio.startCaptureCalled
        XCTAssertTrue(startCaptureCalled)
        guard case .recording(mode: .holdToTalk) = harness.coordinator.flowStateForTesting else {
            return XCTFail("Expected hold-to-talk recording, got \(harness.coordinator.flowStateForTesting)")
        }
        if case .error = harness.coordinator.overlayStateForTesting {
            XCTFail("An already-granted hold-to-talk start should not show a start-failure overlay")
        }

        harness.coordinator.stopDictation()
        let leftRecording = await waitUntil {
            !self.isFlowRecording(harness.coordinator.flowStateForTesting)
        }
        XCTAssertTrue(leftRecording, "Releasing hold-to-talk must leave the recording state")
    }

    func testHoldToTalkSecondHoldStartsCaptureAfterMicSheetGrant() async throws {
        let harness = try await makeMicPermissionHarness(
            microphonePermission: .notDetermined,
            requestMicResult: true
        )

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)

        let returnedToIdle = await waitUntil {
            harness.coordinator.flowStateForTesting == .idle
                && harness.permissionService.requestMicrophonePermissionCallCount == 1
        }
        XCTAssertTrue(returnedToIdle)
        var startCaptureCalled = await harness.audio.startCaptureCalled
        XCTAssertFalse(startCaptureCalled)

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)

        let started = await waitUntil {
            if case .recording(mode: .holdToTalk) = harness.coordinator.flowStateForTesting {
                return true
            }
            return false
        }
        XCTAssertTrue(
            started,
            "The hold after the system mic sheet must start hold-to-talk capture"
        )
        XCTAssertEqual(harness.permissionService.requestMicrophonePermissionCallCount, 1)
        startCaptureCalled = await harness.audio.startCaptureCalled
        XCTAssertTrue(startCaptureCalled)

        harness.coordinator.stopDictation()
        let leftRecording = await waitUntil {
            !self.isFlowRecording(harness.coordinator.flowStateForTesting)
        }
        XCTAssertTrue(leftRecording, "The second hold must leave recording before the test exits")
    }

    func testHoldToTalkDeniedMicrophoneDoesNotStartCapture() async throws {
        let harness = try await makeMicPermissionHarness(
            microphonePermission: .denied,
            requestMicResult: false
        )
        harness.coordinator.testHook_skipMicPermissionAlert = true

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)

        let failed = await waitUntil {
            harness.coordinator.flowStateForTesting
                == .finishing(outcome: .error("Microphone access required"))
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(harness.permissionService.requestMicrophonePermissionCallCount, 0)
        let startCaptureCalled = await harness.audio.startCaptureCalled
        XCTAssertFalse(startCaptureCalled)
        guard case .error(let message) = harness.coordinator.overlayStateForTesting else {
            return XCTFail("Denied mic should show the start-failure overlay")
        }
        XCTAssertEqual(message, "Microphone access required")
    }

    func testHoldToTalkSheetDenialDoesNotStartCapture() async throws {
        let harness = try await makeMicPermissionHarness(
            microphonePermission: .notDetermined,
            requestMicResult: false
        )
        harness.coordinator.testHook_skipMicPermissionAlert = true

        harness.coordinator.startDictation(mode: .holdToTalk, trigger: .hotkey)

        let failed = await waitUntil {
            harness.coordinator.flowStateForTesting
                == .finishing(outcome: .error("Microphone access required"))
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(harness.permissionService.requestMicrophonePermissionCallCount, 1)
        XCTAssertEqual(harness.permissionService.microphonePermission, .denied)
        let startCaptureCalled = await harness.audio.startCaptureCalled
        XCTAssertFalse(startCaptureCalled)
        guard case .error(let message) = harness.coordinator.overlayStateForTesting else {
            return XCTFail("A denied mic sheet should show the start-failure overlay")
        }
        XCTAssertEqual(message, "Microphone access required")
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
            .finishing(outcome: .postPasteActionSuppressed("Pasted, but Return was not sent.")),
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
            .finishing(outcome: .postPasteActionSuppressed("Pasted, but Return was not sent.")),
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
            .finishing(outcome: .postPasteActionSuppressed("Pasted, but Return was not sent.")),
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

    func testStreamingPartialInsertMessageReportsClipboardWhenCopied() {
        XCTAssertEqual(
            DictationFlowCoordinator.streamingPartialInsertMessage(copiedToClipboard: true),
            "Some text was inserted. The full transcript is on the clipboard."
        )
    }

    func testStreamingPartialInsertMessageReportsClipboardFailureWhenNotCopied() {
        XCTAssertEqual(
            DictationFlowCoordinator.streamingPartialInsertMessage(copiedToClipboard: false),
            "Some text was inserted, but the clipboard could not be updated."
        )
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
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(
                for: ClipboardServiceError.requiredFrontmostApplicationUnavailable
            ),
            "paste_frontmost_application_changed"
        )
    }

    func testCommandFailureBucketSplitsStreamingCursorFailures() {
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: StreamingCursorError.eventSourceUnavailable),
            "streaming_event_source_unavailable"
        )
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: StreamingCursorError.eventCreationFailed),
            "streaming_event_creation_failed"
        )
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: StreamingCursorError.partialInsert),
            "streaming_partial_insert"
        )
    }

    private func makeMicPermissionHarness(
        microphonePermission: PermissionStatus,
        requestMicResult: Bool
    ) async throws -> MicPermissionHarness {
        let dbManager = try DatabaseManager()
        let audio = MockAudioProcessor()
        let stt = MockSTTClient()
        let repo = DictationRepository(dbQueue: dbManager.dbQueue)
        let service = DictationService(
            audioProcessor: audio,
            sttTranscriber: stt,
            dictationRepo: repo
        )

        let settingsDefaults = makeTestDefaults(prefix: "mic-permission-settings")
        settingsDefaults.set(false, forKey: UserDefaultsAppRuntimePreferences.showIdlePillKey)
        let settings = SettingsViewModel(defaults: settingsDefaults)

        let preferences = UserDefaultsAppRuntimePreferences(
            defaults: makeTestDefaults(prefix: "mic-permission-preferences")
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

    private func makeRecordingHarness(
        autoSubmitCodexDictation: Bool = false,
        focusedContext: AppPromptContext? = nil,
        mutationArbiter: GUIMutationArbiter? = nil
    ) async throws -> RecordingHarness {
        let dbManager = try DatabaseManager()
        let audio = MockAudioProcessor()
        let stt = MockSTTClient()
        let clipboard = MockClipboardService()
        let repo = DictationRepository(dbQueue: dbManager.dbQueue)
        let service = DictationService(
            audioProcessor: audio,
            sttTranscriber: stt,
            dictationRepo: repo
        )

        let settingsDefaults = makeTestDefaults(prefix: "recording-settings")
        settingsDefaults.set(false, forKey: UserDefaultsAppRuntimePreferences.showIdlePillKey)
        let settings = SettingsViewModel(defaults: settingsDefaults)
        let preferenceDefaults = makeTestDefaults(prefix: "recording-preferences")
        preferenceDefaults.set(
            autoSubmitCodexDictation,
            forKey: UserDefaultsAppRuntimePreferences.autoSubmitCodexDictationKey
        )
        let preferences = UserDefaultsAppRuntimePreferences(defaults: preferenceDefaults)
        let entitlements = EntitlementsService(
            config: LicensingConfig(checkoutURL: nil, expectedVariantID: nil),
            store: InMemoryKeyValueStore(),
            api: StubLicenseAPI()
        )

        let coordinator = DictationFlowCoordinator(
            dictationService: service,
            mutationArbiter: mutationArbiter,
            clipboardService: clipboard,
            entitlementsService: entitlements,
            dictationRepo: repo,
            settingsViewModel: settings,
            sttRuntime: AlwaysReadySTTReadinessChecker(),
            runtimePreferences: preferences,
            permissionService: MockPermissionService(),
            focusedAppContextService: StaticFocusedAppContextProvider(context: focusedContext),
            overlayControllerFactory: { MicPermissionSpyDictationOverlayController(viewModel: $0) },
            onMenuBarIconUpdate: { _ in },
            onHistoryReload: {},
            onPresentEntitlementsAlert: { _ in }
        )

        return RecordingHarness(
            coordinator: coordinator,
            audio: audio,
            stt: stt,
            clipboard: clipboard,
            repo: repo
        )
    }

    private func makeTestDefaults(prefix: String) -> UserDefaults {
        let suiteName = "\(prefix)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func waitUntil(
        timeoutMs: UInt64 = 1200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        return condition()
    }

    private func waitUntilAsync(
        timeoutMs: UInt64 = 2_500,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        return await condition()
    }

    private func isFlowRecording(_ state: DictationFlowState) -> Bool {
        if case .recording = state { return true }
        return false
    }

    private struct MicPermissionHarness {
        let coordinator: DictationFlowCoordinator
        let audio: MockAudioProcessor
        let permissionService: MockPermissionService
    }

    private struct RecordingHarness {
        let coordinator: DictationFlowCoordinator
        let audio: MockAudioProcessor
        let stt: MockSTTClient
        let clipboard: MockClipboardService
        let repo: DictationRepository
    }
}

private struct AlwaysReadySTTReadinessChecker: DictationSTTReadinessChecking {
    func isReady() async -> Bool { true }
}

private struct StaticFocusedAppContextProvider: FocusedAppContextProviding {
    let context: AppPromptContext?

    @MainActor
    func currentContext() -> AppPromptContext? { context }
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

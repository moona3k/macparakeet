import XCTest
import IOKit.hidsystem
@testable import MacParakeet
@testable import MacParakeetCore

final class HotkeyManagerTests: XCTestCase {
    private let leftOptionMask = UInt64(NX_DEVICELALTKEYMASK)
    private let rightOptionMask = UInt64(NX_DEVICERALTKEYMASK)
    private let leftShiftMask = UInt64(NX_DEVICELSHIFTKEYMASK)
    private let rightShiftMask = UInt64(NX_DEVICERSHIFTKEYMASK)
    private let leftCommandMask = UInt64(NX_DEVICELCMDKEYMASK)
    private let rightCommandMask = UInt64(NX_DEVICERCMDKEYMASK)

    private func sideSpecificFlags(_ masks: UInt64...) -> CGEventFlags {
        CGEventFlags(rawValue: masks.reduce(0, |))
    }

    func testDoubleTapOnlyGestureModeDoesNotStartHoldRecording() {
        let manager = HotkeyManager(trigger: .fn, gestureMode: .doubleTapOnly)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .showReadyForSecondTap,
            ]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_100
            ),
            [.startRecording(mode: .persistent)]
        )
    }

    func testHoldOnlyGestureModeStartsAndStopsHoldRecording() {
        let manager = HotkeyManager(trigger: .fn, gestureMode: .holdOnly)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
    }

    func testSingleTapToggleModifierStartsOnBareReleaseAndStopsOnNextBareRelease() {
        let manager = HotkeyManager(trigger: .fn, gestureMode: .singleTapToggle)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            [.startRecording(mode: .persistent)]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_200
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250
            ),
            [.stopRecording]
        )
    }

    func testSingleTapToggleModifierIgnoresNonBareShortcutUse() {
        let manager = HotkeyManager(trigger: .command, gestureMode: .singleTapToggle)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskCommand],
                timestampMs: 1_000
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 8, timestampMs: 1_025),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            []
        )
    }

    func testHoldOnlyCommandCancelsBeforeStartupWhenUsedAsChord() {
        let manager = HotkeyManager(trigger: .command, gestureMode: .holdOnly)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskCommand],
                timestampMs: 1_000
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 8, timestampMs: 1_025),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
    }

    func testSuppressedHoldOnlyManagerDoesNotStartUntilReset() {
        let manager = HotkeyManager(trigger: .fn, gestureMode: .holdOnly)

        manager.suppressUntilReset()

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_100
            ),
            []
        )

        manager.resetToIdle(flags: [])

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_200
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
    }

    func testDoubleTapOnlyGestureModeWorksForKeyCodeTriggers() {
        let trigger = HotkeyTrigger.fromKeyCode(119)
        let manager = HotkeyManager(trigger: trigger, gestureMode: .doubleTapOnly)

        let firstDown = manager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 119,
            timestampMs: 1_000
        )
        XCTAssertEqual(firstDown.outputs, [])
        XCTAssertTrue(firstDown.shouldSwallow)
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])

        let firstUp = manager.keyCodeEventDecisionForTesting(
            type: .keyUp,
            keyCode: 119,
            timestampMs: 1_050
        )
        XCTAssertEqual(firstUp.outputs, [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap])
        XCTAssertTrue(firstUp.shouldSwallow)

        let secondDown = manager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 119,
            timestampMs: 1_100
        )
        XCTAssertEqual(secondDown.outputs, [.startRecording(mode: .persistent)])
        XCTAssertTrue(secondDown.shouldSwallow)
    }

    func testHoldOnlyGestureModeWorksForKeyCodeTriggers() {
        let trigger = HotkeyTrigger.fromKeyCode(119)
        let manager = HotkeyManager(trigger: trigger, gestureMode: .holdOnly)

        let keyDown = manager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 119,
            timestampMs: 1_000
        )
        XCTAssertEqual(
            keyDown.outputs,
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertTrue(keyDown.shouldSwallow)
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

        let keyUp = manager.keyCodeEventDecisionForTesting(
            type: .keyUp,
            keyCode: 119,
            timestampMs: 1_250
        )
        XCTAssertEqual(
            keyUp.outputs,
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
        XCTAssertTrue(keyUp.shouldSwallow)
    }

    func testSingleTapToggleGestureModeWorksForKeyCodeTriggers() {
        let trigger = HotkeyTrigger.fromKeyCode(119)
        let manager = HotkeyManager(trigger: trigger, gestureMode: .singleTapToggle)

        let firstDown = manager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 119,
            timestampMs: 1_000
        )
        XCTAssertEqual(firstDown.outputs, [.startRecording(mode: .persistent)])
        XCTAssertTrue(firstDown.shouldSwallow)

        let firstUp = manager.keyCodeEventDecisionForTesting(
            type: .keyUp,
            keyCode: 119,
            timestampMs: 1_050
        )
        XCTAssertEqual(firstUp.outputs, [])
        XCTAssertTrue(firstUp.shouldSwallow)

        let secondDown = manager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 119,
            timestampMs: 1_200
        )
        XCTAssertEqual(secondDown.outputs, [.stopRecording])
        XCTAssertTrue(secondDown.shouldSwallow)
    }

    func testHoldOnlyGestureModeStopsChordWhenRequiredModifierReleasesFirst() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 15)
        let manager = HotkeyManager(trigger: trigger, gestureMode: .holdOnly)

        let keyDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 15,
            flags: trigger.chordEventFlags,
            timestampMs: 1_000
        )
        XCTAssertEqual(
            keyDown.outputs,
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertTrue(keyDown.shouldSwallow)
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

        let flagsChanged = manager.chordEventDecisionForTesting(
            type: .flagsChanged,
            keyCode: 0,
            flags: 0,
            timestampMs: 1_250
        )
        XCTAssertEqual(
            flagsChanged.outputs,
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
        XCTAssertFalse(flagsChanged.shouldSwallow)

        let keyUp = manager.chordEventDecisionForTesting(
            type: .keyUp,
            keyCode: 15,
            flags: 0,
            timestampMs: 1_300
        )
        XCTAssertEqual(keyUp.outputs, [])
        XCTAssertTrue(keyUp.shouldSwallow)
    }

    func testSingleTapToggleGestureModeWorksForFnSpaceChord() {
        let trigger = HotkeyTrigger.fnSpace
        let manager = HotkeyManager(trigger: trigger, gestureMode: .singleTapToggle)

        let firstDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 49,
            flags: trigger.chordEventFlags,
            timestampMs: 1_000
        )
        XCTAssertEqual(firstDown.outputs, [.startRecording(mode: .persistent)])
        XCTAssertTrue(firstDown.shouldSwallow)

        let firstUp = manager.chordEventDecisionForTesting(
            type: .keyUp,
            keyCode: 49,
            flags: trigger.chordEventFlags,
            timestampMs: 1_050
        )
        XCTAssertEqual(firstUp.outputs, [])
        XCTAssertTrue(firstUp.shouldSwallow)

        let secondDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 49,
            flags: trigger.chordEventFlags,
            timestampMs: 1_200
        )
        XCTAssertEqual(secondDown.outputs, [.stopRecording])
        XCTAssertTrue(secondDown.shouldSwallow)
    }

    func testControlFunctionKeyChordToleratesPhantomFnFlagBit() {
        // Characterization: chord matching is superset-based, so a clean
        // ⌃F19 trigger fires whether or not the event carries the phantom
        // NX_SECONDARYFNMASK bit macOS sets on hardware F-key presses.
        // The recorder relies on this to store F-key chords without "fn".
        let trigger = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 80)

        for phantomFn in [CGEventFlags.maskSecondaryFn.rawValue, 0] {
            let manager = HotkeyManager(trigger: trigger, gestureMode: .singleTapToggle)

            let keyDown = manager.chordEventDecisionForTesting(
                type: .keyDown,
                keyCode: 80,
                flags: trigger.chordEventFlags | phantomFn,
                timestampMs: 1_000
            )
            XCTAssertEqual(keyDown.outputs, [.startRecording(mode: .persistent)])
            XCTAssertTrue(keyDown.shouldSwallow)
        }
    }

    func testDefaultFnSpaceChordCancelsPendingPushToTalkBeforeHandsFreeStarts() {
        let pushToTalk = HotkeyManager(
            trigger: .defaultPushToTalk,
            gestureMode: .holdOnly,
            startupDebounceMs: FnKeyStateMachine.defaultTapThresholdMs
        )
        let handsFree = HotkeyManager(trigger: .fnSpace, gestureMode: .singleTapToggle)

        XCTAssertEqual(
            pushToTalk.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultTapThresholdMs)]
        )

        XCTAssertEqual(
            pushToTalk.modifierKeyDownOutputsForTesting(keyCode: 49, timestampMs: 1_200),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
        XCTAssertEqual(pushToTalk.startupDebounceElapsedForTesting(), [])

        let handsFreeStart = handsFree.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 49,
            flags: HotkeyTrigger.fnSpace.chordEventFlags,
            timestampMs: 1_200
        )
        XCTAssertEqual(handsFreeStart.outputs, [.startRecording(mode: .persistent)])
        XCTAssertTrue(handsFreeStart.shouldSwallow)
    }

    func testHoldOnlyGestureModeWorksForModifierChordTriggers() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["control", "option"])
        let manager = HotkeyManager(trigger: trigger, gestureMode: .holdOnly)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskControl, .maskAlternate],
                timestampMs: 1_000
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_250
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
    }

    func testSingleTapToggleModifierChordStartsOnBareRelease() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["control", "option"])
        let manager = HotkeyManager(trigger: trigger, gestureMode: .singleTapToggle)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskControl, .maskAlternate],
                timestampMs: 1_000
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_050
            ),
            [.startRecording(mode: .persistent)]
        )
    }

    func testTapRecoveryResetsPendingModifierGesture() {
        let manager = HotkeyManager(trigger: .fn)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )

        manager.recoverFromDisabledTapForTesting(flags: [])

        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_100
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testTapRecoveryResyncsStillHeldModifierWithoutReleaseOutput() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )

        manager.recoverFromDisabledTapForTesting(flags: [.maskSecondaryFn])

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_100
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testTapRecoveryDuringActiveHoldToTalkStopsOnRelease() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )

        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_150
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_500
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
    }

    func testTapRecoveryDuringActiveHoldWithAdditionalModifierCancelsOnRelease() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])

        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_200
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_300
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
    }

    func testTapRecoveryDuringSideSpecificHoldWithOppositeSideCancelsOnRelease() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask
            ),
            timestampMs: 1_000
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])

        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    leftOptionMask,
                    rightOptionMask
                ),
                timestampMs: 1_200
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    leftOptionMask
                ),
                timestampMs: 1_300
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
    }

    func testTapRecoveryDuringActiveHoldToTalkStopsIfReleaseWasMissed() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )

        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [],
                timestampMs: 1_500
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_600
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testTapRecoveryDuringPersistentRecordingPreservesStopGesture() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [],
            timestampMs: 1_050
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_100
            ),
            [.startRecording(mode: .persistent)]
        )

        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [],
                timestampMs: 1_150
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_200
            ),
            [.stopRecording]
        )
    }

    func testTapRecoveryDuringActiveChordHoldStopsAndSuppressesLaterKeyUp() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 49)
        let manager = HotkeyManager(trigger: trigger)

        manager.resumeRecording(mode: .holdToTalk)

        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [],
                triggerKeyPressed: true,
                timestampMs: 1_500
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
        XCTAssertEqual(
            manager.chordTriggerKeyUpOutputsForTesting(timestampMs: 1_550),
            []
        )
    }

    func testSyncedPersistentRecordingFromExternalSurfaceMakesFnPressStop() {
        let manager = HotkeyManager(trigger: .fn)

        manager.syncRecordingMode(.persistent)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [.stopRecording]
        )
    }

    func testSyncedPersistentRecordingSuppressesHoldOnlyPeerUntilReset() {
        let manager = HotkeyManager(trigger: .option, gestureMode: .holdOnly)

        manager.syncRecordingMode(.persistent)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlternate],
                timestampMs: 1_000
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])

        manager.resetToIdle(flags: [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlternate],
                timestampMs: 2_000
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
    }

    func testChordTriggerKeyUpPassesThroughWhenChordWasNotHandled() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 15)
        let manager = HotkeyManager(trigger: trigger)

        let keyDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 15,
            flags: 0,
            timestampMs: 1_000
        )
        let keyUp = manager.chordEventDecisionForTesting(
            type: .keyUp,
            keyCode: 15,
            flags: 0,
            timestampMs: 1_050
        )

        XCTAssertEqual(keyDown.outputs, [])
        XCTAssertFalse(keyDown.shouldSwallow)
        XCTAssertEqual(keyUp.outputs, [])
        XCTAssertFalse(keyUp.shouldSwallow)
    }

    func testChordTriggerKeyUpSwallowsAfterHandledKeyDown() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 15)
        let manager = HotkeyManager(trigger: trigger)

        let keyDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 15,
            flags: trigger.chordEventFlags,
            timestampMs: 1_000
        )
        let keyUp = manager.chordEventDecisionForTesting(
            type: .keyUp,
            keyCode: 15,
            flags: trigger.chordEventFlags,
            timestampMs: 1_050
        )

        XCTAssertEqual(
            keyDown.outputs,
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
        XCTAssertTrue(keyDown.shouldSwallow)
        XCTAssertEqual(keyUp.outputs, [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap])
        XCTAssertTrue(keyUp.shouldSwallow)
    }

    func testChordTriggerWithoutRequiredModifiersInterruptsPendingSecondTap() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 15)
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 15,
            flags: trigger.chordEventFlags,
            timestampMs: 1_000
        )
        _ = manager.chordEventDecisionForTesting(
            type: .keyUp,
            keyCode: 15,
            flags: trigger.chordEventFlags,
            timestampMs: 1_050
        )

        let bareKeyDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 15,
            flags: 0,
            timestampMs: 1_100
        )
        let bareKeyUp = manager.chordEventDecisionForTesting(
            type: .keyUp,
            keyCode: 15,
            flags: 0,
            timestampMs: 1_150
        )
        let nextChordKeyDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 15,
            flags: trigger.chordEventFlags,
            timestampMs: 1_200
        )

        XCTAssertEqual(bareKeyDown.outputs, [.cancelStartupDebounce, .cancelHoldWindow])
        XCTAssertFalse(bareKeyDown.shouldSwallow)
        XCTAssertEqual(bareKeyUp.outputs, [])
        XCTAssertFalse(bareKeyUp.shouldSwallow)
        XCTAssertEqual(
            nextChordKeyDown.outputs,
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
        XCTAssertTrue(nextChordKeyDown.shouldSwallow)
    }

    func testChordTriggerKeyUpSwallowsAfterModifierReleasedFirst() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 15)
        let manager = HotkeyManager(trigger: trigger)

        let keyDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 15,
            flags: trigger.chordEventFlags,
            timestampMs: 1_000
        )
        let flagsChanged = manager.chordEventDecisionForTesting(
            type: .flagsChanged,
            keyCode: 0,
            flags: 0,
            timestampMs: 1_050
        )
        let keyUp = manager.chordEventDecisionForTesting(
            type: .keyUp,
            keyCode: 15,
            flags: 0,
            timestampMs: 1_100
        )

        XCTAssertTrue(keyDown.shouldSwallow)
        XCTAssertEqual(
            flagsChanged.outputs,
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
        XCTAssertFalse(flagsChanged.shouldSwallow)
        XCTAssertEqual(keyUp.outputs, [])
        XCTAssertTrue(keyUp.shouldSwallow)
    }

    func testAdditionalModifierInterruptsBareFnBeforeStartup() {
        let manager = HotkeyManager(trigger: .fn)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_050
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_100
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
    }

    func testRegularKeyInterruptsBareFnAndCancelsPendingTimers() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )

        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(
                keyCode: 0,
                timestampMs: 1_050
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
    }

    func testRegularKeyInterruptsConfirmedFnHoldAndCancelsImmediately() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )
        XCTAssertEqual(
            manager.holdWindowElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )

        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(
                keyCode: 0,
                timestampMs: 1_450
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_500
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
    }

    func testAdditionalModifierSilentlyDiscardsAfterProvisionalStartup() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )

        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_175
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .discardRecording(showReadyPill: false),
            ]
        )
    }

    // MARK: - Side-Specific Modifier Detection

    func testSideSpecificRightCommandTriggersFromChangedKeyCodeWhenSideFlagsAreMissing() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskCommand],
                timestampMs: 1_000,
                changedKeyCode: 54
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testSideSpecificRightCommandIgnoresLeftCommandWhenSideFlagsAreMissing() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskCommand],
                timestampMs: 1_000,
                changedKeyCode: 55
            ),
            []
        )
    }

    func testSideSpecificRightCommandReleaseFromChangedKeyCodeWhenSideFlagsAreMissing() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskCommand],
            timestampMs: 1_000,
            changedKeyCode: 54
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050,
                changedKeyCode: 54
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
    }

    func testHoldOnlySideSpecificCommandCancelsBeforeStartupWhenUsedAsChord() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        let manager = HotkeyManager(trigger: trigger, gestureMode: .holdOnly)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskCommand],
                timestampMs: 1_000,
                changedKeyCode: 54
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 8, timestampMs: 1_025),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
    }

    func testSideSpecificRightOptionOnlyTriggersOnRightKey() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Right option pressed (keyCode 61) — should trigger
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    rightOptionMask
                ),
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testSideSpecificRightOptionIgnoresLeftKey() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Left option pressed (keyCode 58) — should NOT trigger
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    leftOptionMask
                ),
                timestampMs: 1_000
            ),
            []
        )
    }

    func testSideSpecificRightOptionTapReleaseProducesTriggerReleased() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Press right option
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask
            ),
            timestampMs: 1_000
        )

        // Release right option (within tap threshold)
        let outputs = manager.modifierFlagsChangedOutputsForTesting(
            flags: [],
            timestampMs: 1_050
        )

        XCTAssertEqual(outputs, [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap])
    }

    func testSideSpecificOtherKeyInterruptsWhileHeld() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Press right option
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask
            ),
            timestampMs: 1_000
        )

        // Left option pressed while right is held — should interrupt bare-tap
        let outputs = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                leftOptionMask,
                rightOptionMask
            ),
            timestampMs: 1_050
        )
        XCTAssertEqual(outputs, [.cancelStartupDebounce, .cancelHoldWindow] as [HotkeyGestureController.Output])
    }

    func testSideSpecificOppositeSideTapCancelsPendingSecondTap() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    rightOptionMask
                ),
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    leftOptionMask
                ),
                timestampMs: 1_100
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_150
            ),
            []
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    rightOptionMask
                ),
                timestampMs: 1_200
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testSideSpecificOppositeSideTapCancelsPendingSecondTapWhenSideFlagsAreMissing() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskCommand],
                timestampMs: 1_000,
                changedKeyCode: 54
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050,
                changedKeyCode: 54
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskCommand],
                timestampMs: 1_100,
                changedKeyCode: 55
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_150,
                changedKeyCode: 55
            ),
            []
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskCommand],
                timestampMs: 1_200,
                changedKeyCode: 54
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testSideSpecificRightOptionIgnoresPressWhenLeftOptionAlreadyHeld() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                leftOptionMask
            ),
            timestampMs: 1_000
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    leftOptionMask,
                    rightOptionMask
                ),
                timestampMs: 1_050
            ),
            []
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    leftOptionMask
                ),
                timestampMs: 1_100
            ),
            []
        )
    }

    func testSideSpecificRightOptionReleaseWhileHeldAtStartupDoesNotInvertState() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        manager.syncModifierPressedStateForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask
            )
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_000
            ),
            []
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    rightOptionMask
                ),
                timestampMs: 1_050
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testSideSpecificRightOptionResyncAfterMissedReleaseAllowsNextPress() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask
            ),
            timestampMs: 1_000
        )

        manager.syncModifierPressedStateForTesting(flags: [])

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    rightOptionMask
                ),
                timestampMs: 1_050
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testResetToIdleResyncsHeldSideSpecificModifierState() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask
            ),
            timestampMs: 1_000
        )

        manager.resetToIdle(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask
            )
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    CGEventFlags.maskShift.rawValue,
                    rightOptionMask,
                    leftShiftMask
                ),
                timestampMs: 1_050
            ),
            []
        )
    }

    func testSideSpecificCapsLockDoesNotInterruptBareTap() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Press right option
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask
            ),
            timestampMs: 1_000
        )

        // Caps Lock toggled (keyCode 57) while right option is held — should NOT interrupt
        let outputs = manager.modifierFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                rightOptionMask,
                UInt64(CGEventFlags.maskAlphaShift.rawValue)
            ),
            timestampMs: 1_050
        )
        XCTAssertEqual(outputs, [])

        // Release right option — should still be treated as bare tap
        let releaseOutputs = manager.modifierFlagsChangedOutputsForTesting(
            flags: CGEventFlags(rawValue: UInt64(CGEventFlags.maskAlphaShift.rawValue)),
            timestampMs: 1_100
        )
        XCTAssertEqual(releaseOutputs, [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap])
    }

    func testGenericOptionStillTriggersOnEitherSide() {
        // Generic trigger (no modifierKeyCode) — both sides should work
        let manager = HotkeyManager(trigger: .option)

        // Left option pressed
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlternate],
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    // MARK: - Modifier-Only Chord Detection

    func testModifierChordTapReleaseProducesReadyForSecondTap() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskCommand, .maskAlternate],
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
    }

    func testModifierChordDoubleTapStartsPersistentRecording() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierChordFlagsChangedOutputsForTesting(
            flags: [.maskCommand, .maskAlternate],
            timestampMs: 1_000
        )
        _ = manager.modifierChordFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_050)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskCommand, .maskAlternate],
                timestampMs: 1_100
            ),
            [.startRecording(mode: .persistent)]
        )
    }

    func testModifierChordHoldToTalkStopsOnRelease() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierChordFlagsChangedOutputsForTesting(
            flags: [.maskCommand, .maskAlternate],
            timestampMs: 1_000
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_450
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
    }

    func testModifierChordRegularKeyInterruptsBareTap() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierChordFlagsChangedOutputsForTesting(
            flags: [.maskCommand, .maskAlternate],
            timestampMs: 1_000
        )

        XCTAssertEqual(
            manager.modifierChordKeyDownOutputsForTesting(
                keyCode: 46,
                timestampMs: 1_025
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
    }

    func testModifierChordExtraModifierInterruptsBareTap() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierChordFlagsChangedOutputsForTesting(
            flags: [.maskCommand, .maskAlternate],
            timestampMs: 1_000
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskCommand, .maskAlternate, .maskShift],
                timestampMs: 1_025
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
    }

    func testModifierChordDoesNotStartAfterSupersetModifierIsReleased() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskCommand, .maskAlternate, .maskShift],
                timestampMs: 1_000
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [.maskCommand, .maskAlternate],
                timestampMs: 1_025
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_050),
            []
        )
    }

    func testSideSpecificModifierChordRequiresRecordedSides() {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ]
        )
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    CGEventFlags.maskCommand.rawValue,
                    rightOptionMask,
                    rightCommandMask
                ),
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
    }

    func testSideSpecificSameModifierChordRequiresBothRecordedSides() {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "shift", keyCode: 56),
                .init(modifierName: "shift", keyCode: 60),
            ]
        )
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskShift.rawValue,
                    leftShiftMask
                ),
                timestampMs: 1_000
            ),
            []
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskShift.rawValue,
                    leftShiftMask,
                    rightShiftMask
                ),
                timestampMs: 1_025
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testSideSpecificModifierChordIgnoresOppositeSides() {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ]
        )
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    CGEventFlags.maskCommand.rawValue,
                    leftOptionMask,
                    leftCommandMask
                ),
                timestampMs: 1_000
            ),
            []
        )
    }

    func testSideSpecificModifierChordDoesNotStartAfterOppositeSideIsReleased() {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ]
        )
        let manager = HotkeyManager(trigger: trigger)

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    CGEventFlags.maskCommand.rawValue,
                    leftOptionMask,
                    rightOptionMask,
                    rightCommandMask
                ),
                timestampMs: 1_000
            ),
            []
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    CGEventFlags.maskCommand.rawValue,
                    rightOptionMask,
                    rightCommandMask
                ),
                timestampMs: 1_025
            ),
            []
        )

        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_050),
            []
        )
    }

    func testTapRecoveryDuringSideSpecificModifierChordHoldWithOppositeSideCancelsOnRelease() {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ]
        )
        let manager = HotkeyManager(trigger: trigger)

        _ = manager.modifierChordFlagsChangedOutputsForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                CGEventFlags.maskCommand.rawValue,
                rightOptionMask,
                rightCommandMask
            ),
            timestampMs: 1_000
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])

        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: sideSpecificFlags(
                    CGEventFlags.maskAlternate.rawValue,
                    CGEventFlags.maskCommand.rawValue,
                    leftOptionMask,
                    rightOptionMask,
                    rightCommandMask
                ),
                timestampMs: 1_200
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierChordFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_300
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
    }
}

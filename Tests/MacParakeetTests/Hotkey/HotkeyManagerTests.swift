import XCTest
import IOKit.hidsystem
@testable import MacParakeet
@testable import MacParakeetCore

final class HotkeyManagerTests: XCTestCase {
    private let leftOptionMask = UInt64(NX_DEVICELALTKEYMASK)
    private let rightOptionMask = UInt64(NX_DEVICERALTKEYMASK)
    private let leftShiftMask = UInt64(NX_DEVICELSHIFTKEYMASK)
    private let leftCommandMask = UInt64(NX_DEVICELCMDKEYMASK)
    private let rightCommandMask = UInt64(NX_DEVICERCMDKEYMASK)

    private func sideSpecificFlags(_ masks: UInt64...) -> CGEventFlags {
        CGEventFlags(rawValue: masks.reduce(0, |))
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

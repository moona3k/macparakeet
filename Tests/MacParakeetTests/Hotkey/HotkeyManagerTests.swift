import XCTest
import IOKit.hidsystem
@testable import MacParakeet
@testable import MacParakeetCore

final class HotkeyManagerTests: XCTestCase {
    private let leftOptionMask = UInt64(NX_DEVICELALTKEYMASK)
    private let rightOptionMask = UInt64(NX_DEVICERALTKEYMASK)
    private let leftShiftMask = UInt64(NX_DEVICELSHIFTKEYMASK)

    private func sideSpecificFlags(_ masks: UInt64...) -> CGEventFlags {
        CGEventFlags(rawValue: masks.reduce(0, |))
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
}

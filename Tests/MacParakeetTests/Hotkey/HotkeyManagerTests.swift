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

    /// Builds a manager that sees no pre-held keys. Built-in Fn is admitted
    /// only when no other key is held, and the production provider reads the
    /// live session keyboard, so a key the OS reports as stuck on the test
    /// machine would otherwise reject every Fn gesture. Tests that model
    /// held keys install their own provider afterward.
    private func makeManager(
        trigger: HotkeyTrigger,
        gestureMode: HotkeyGestureController.Mode = .doubleTapAndHold
    ) -> HotkeyManager {
        let manager = HotkeyManager(trigger: trigger, gestureMode: gestureMode)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        return manager
    }

    /// #1142: dictation taps, including filtering non-Fn triggers, must not
    /// share the UI run loop.
    func testTapRunsOnEventTapThreadNotMainRunLoop() throws {
        for trigger in [HotkeyTrigger.fn, .chord(modifiers: ["control", "shift"], keyCode: 15)] {
            let manager = makeManager(trigger: trigger)
            guard manager.start() else {
                throw XCTSkip("Event tap creation needs Input Monitoring permission")
            }
            let source = try XCTUnwrap(manager.runLoopSourceForTesting)
            XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
            XCTAssertTrue(CFRunLoopContainsSource(EventTapThread.shared.runLoop, source, .commonModes))
            manager.stop()
            XCTAssertNil(manager.runLoopSourceForTesting)
        }
    }

    func testStartStopCyclesDoNotAccumulateEventTaps() throws {
        let manager = makeManager(trigger: .chord(modifiers: ["control", "shift"], keyCode: 15))
        guard manager.start() else {
            throw XCTSkip("Event tap creation needs Input Monitoring permission")
        }
        manager.stop()
        let baseline = try XCTUnwrap(eventTapCountForThisProcess())
        for _ in 0..<10 {
            XCTAssertTrue(manager.start())
            XCTAssertTrue(manager.start())
            manager.stop()
        }
        XCTAssertEqual(eventTapCountForThisProcess(), baseline)
    }

    func testBareFnUsesListenOnlyTapWithoutChangingOtherHotkeyTapBehavior() {
        let keyUpMask: CGEventMask = 1 << CGEventType.keyUp.rawValue

        XCTAssertEqual(HotkeyManager.eventTapOptions(for: .fn), .listenOnly)
        XCTAssertEqual(HotkeyManager.eventTapOptions(for: .control), .defaultTap)
        XCTAssertEqual(HotkeyManager.eventTapOptions(for: .fnSpace), .defaultTap)
        XCTAssertEqual(
            HotkeyManager.eventTapOptions(for: .fromKeyCode(119)),
            .defaultTap
        )
        XCTAssertEqual(HotkeyManager.eventMask(for: .fn) & keyUpMask, keyUpMask)
        XCTAssertEqual(HotkeyManager.eventMask(for: .control) & keyUpMask, 0)
    }

    func testPassiveFnCleanHoldReleaseStartsAndStopsExactlyOnceDespiteNoise() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_010,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_260,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
    }

    func testPassiveFnOtherKeyCancellationCannotStopOrRestartOnRelease() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 0, timestampMs: 1_200),
            [.cancelStartupDebounce, .cancelHoldWindow, .cancelRecording]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
    }

    func testPassiveFnPreHeldModifierBlocksEntireGesture() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_250,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
    }

    func testPassiveFnPreHeldOrdinaryKeyRemainingHeldBlocksEntireGesture() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { $0 == 0 }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.modifierKeyUpOutputsForTesting(keyCode: 0, timestampMs: 1_300), [])
    }

    func testPassiveFnPreHeldOrdinaryKeyReleasedDuringFnRemainsCancelled() {
        var pressedKeyCodes: Set<UInt16> = [0]
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { pressedKeyCodes.contains($0) }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        pressedKeyCodes.remove(0)
        XCTAssertEqual(manager.modifierKeyUpOutputsForTesting(keyCode: 0, timestampMs: 1_150), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
    }

    func testPassiveFnSingleTapEscapeHeldThroughReleaseCannotStartRecording() {
        let manager = makeManager(trigger: .fn, gestureMode: .singleTapToggle)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 53, timestampMs: 1_050),
            [.escapeWhileIdle]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.modifierKeyUpOutputsForTesting(keyCode: 53, timestampMs: 1_150), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
    }

    func testEscapeDoesNotCancelWhenSettingIsOff() {
        let manager = makeManager(trigger: .fn, gestureMode: .singleTapToggle)
        manager.shouldCancelOnEscape = { false }
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 53, timestampMs: 1_000),
            [.escapeWhileIdle]
        )

        let keyCodeManager = makeManager(trigger: HotkeyTrigger.fromKeyCode(119), gestureMode: .singleTapToggle)
        keyCodeManager.shouldCancelOnEscape = { false }
        let decision = keyCodeManager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 53,
            timestampMs: 1_000
        )
        XCTAssertEqual(decision.outputs, [.escapeWhileIdle])
        XCTAssertFalse(decision.shouldSwallow)
    }

    func testEscapeDoesNotCancelActiveRecordingWhenSettingIsOff() {
        var cancelOnEscape = false
        let manager = HotkeyManager(
            trigger: HotkeyTrigger.fromKeyCode(119),
            gestureMode: .singleTapToggle
        )
        manager.shouldCancelOnEscape = { cancelOnEscape }

        let start = manager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 119,
            timestampMs: 1_000
        )
        XCTAssertEqual(start.outputs, [.startRecording(mode: .persistent)])

        let ignored = manager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 53,
            timestampMs: 1_100
        )
        XCTAssertEqual(ignored.outputs, [])
        XCTAssertFalse(ignored.shouldSwallow)

        cancelOnEscape = true
        let cancelled = manager.keyCodeEventDecisionForTesting(
            type: .keyDown,
            keyCode: 53,
            timestampMs: 1_200
        )
        XCTAssertEqual(cancelled.outputs, [.cancelRecording])
        XCTAssertFalse(cancelled.shouldSwallow)
    }

    func testEscapeClearsPendingHoldWhenCancelSettingIsOff() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.shouldCancelOnEscape = { false }
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 53, timestampMs: 1_020),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
    }

    func testEscapeClearsSecondTapWindowWhenCancelSettingIsOff() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapAndHold)
        manager.shouldCancelOnEscape = { false }
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
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
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 53, timestampMs: 1_080),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testPassiveFnTapRecoveryReconcilesPreHeldKeyAndFailsClosed() {
        var pressedKeyCodes: Set<UInt16> = []
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { pressedKeyCodes.contains($0) }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        pressedKeyCodes.insert(0)
        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn],
                triggerKeyPressed: true,
                timestampMs: 1_050
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])

        pressedKeyCodes.remove(0)
        XCTAssertEqual(manager.modifierKeyUpOutputsForTesting(keyCode: 0, timestampMs: 1_100), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_150,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])

        // Pressed again: the tap sees the keyDown, so Fn stays blocked. A
        // release the tap saw survives resetToIdle (#1142 follow-up): a stale
        // snapshot key must not block Fn after every take.
        pressedKeyCodes.insert(0)
        _ = manager.modifierKeyDownOutputsForTesting(keyCode: 0, timestampMs: 1_180)
        manager.resetToIdle(flags: [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
    }

    func testPassiveFnContaminatedAdmissionInvalidatesPendingDoubleTapWindow() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_150,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_175,
                changedKeyCode: 59
            ),
            []
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
    }

    func testPassiveFnModifierTransitionBetweenTapsInvalidatesPendingWindow() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlternate],
                timestampMs: 1_100,
                changedKeyCode: 58
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_125,
                changedKeyCode: 58
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_150,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
    }

    func testPassiveFnKeyUpOnlyBetweenTapsInvalidatesPendingWindowOnce() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapAndHold)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
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
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
        XCTAssertEqual(
            manager.modifierKeyUpOutputsForTesting(keyCode: 0, timestampMs: 1_100),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(manager.modifierKeyUpOutputsForTesting(keyCode: 0, timestampMs: 1_125), [])
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_150,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
    }

    func testPassiveFnKeyUpOnlyDoesNotCancelOwnedPersistentRecording() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [],
            timestampMs: 1_050,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.startRecording(mode: .persistent)]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_125,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )

        XCTAssertEqual(manager.modifierKeyUpOutputsForTesting(keyCode: 0, timestampMs: 1_150), [])
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.stopRecording]
        )
    }

    func testPassiveFnContaminatedAdmissionPreservesActivePersistentOwnership() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [],
            timestampMs: 1_050,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.startRecording(mode: .persistent)]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_125,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_150,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_175,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_190,
                changedKeyCode: 59
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.stopRecording]
        )
    }

    func testPassiveFnPreLatchedCapsLockPhysicalKeyStateDoesNotBlockHold() {
        let holdManager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        holdManager.setPhysicalKeyStateProviderForTesting { $0 == 57 }

        XCTAssertEqual(
            holdManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            holdManager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )

        let tapManager = makeManager(trigger: .fn, gestureMode: .doubleTapOnly)
        tapManager.setPhysicalKeyStateProviderForTesting { $0 == 57 }
        XCTAssertEqual(
            tapManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 2_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            tapManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 2_050,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
        XCTAssertEqual(
            tapManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 2_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.startRecording(mode: .persistent)]
        )
    }

    func testPassiveFnPreLatchedCapsLockAllowsHoldAndDoubleTap() {
        let holdManager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        holdManager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            holdManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            holdManager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(
            holdManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording]
        )

        let tapManager = makeManager(trigger: .fn, gestureMode: .doubleTapOnly)
        tapManager.setPhysicalKeyStateProviderForTesting { _ in false }
        XCTAssertEqual(
            tapManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 2_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            tapManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 2_050,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap]
        )
        XCTAssertEqual(
            tapManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 2_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.startRecording(mode: .persistent)]
        )
    }

    func testPassiveFnCapsLockTransitionBetweenTapsAndDuringHoldCancels() {
        let tapManager = makeManager(trigger: .fn, gestureMode: .doubleTapOnly)
        tapManager.setPhysicalKeyStateProviderForTesting { _ in false }

        _ = tapManager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        _ = tapManager.modifierFlagsChangedOutputsForTesting(
            flags: [],
            timestampMs: 1_050,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(
            tapManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 1_100,
                changedKeyCode: 57
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(
            tapManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 1_150,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )

        let holdManager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        holdManager.setPhysicalKeyStateProviderForTesting { _ in false }
        _ = holdManager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 2_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(
            holdManager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(
            holdManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 2_100,
                changedKeyCode: 57
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .cancelRecording]
        )
        XCTAssertEqual(
            holdManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 2_150,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
    }

    func testPassiveFnRecoveryAllowsPreLatchedCapsLockWhenKeyStateReportsDown() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { $0 == 57 }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                triggerKeyPressed: true,
                timestampMs: 1_050
            ),
            []
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
    }

    func testPassiveFnRecoveryAllowsPreLatchedCapsLock() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                triggerKeyPressed: true,
                timestampMs: 1_050
            ),
            []
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording]
        )
    }

    func testPassiveFnRecoveryCancelsPendingGestureWhenCapsLockTurnsOn() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                triggerKeyPressed: true,
                timestampMs: 1_050
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_150,
                changedKeyCode: 57
            ),
            []
        )
    }

    func testPassiveFnRecoveryCancelsPendingGestureWhenCapsLockTurnsOff() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn],
                triggerKeyPressed: true,
                timestampMs: 1_050
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
    }

    func testPassiveFnRecoveryCapsLockDeltaCancelsActiveHoldExactlyOnce() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                triggerKeyPressed: true,
                timestampMs: 1_100
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .cancelRecording]
        )
        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                triggerKeyPressed: true,
                timestampMs: 1_150
            ),
            []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
    }

    func testPassiveFnReleaseOfObservedOtherKeyCancelsGesture() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(
            manager.modifierKeyDownOutputsForTesting(keyCode: 0, timestampMs: 1_150),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ])
        XCTAssertEqual(
            manager.modifierKeyUpOutputsForTesting(keyCode: 0, timestampMs: 1_200),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
    }

    func testPassiveFnOtherModifierTransitionCancelsWithoutPostCancelStop() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_200,
                changedKeyCode: 59
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .cancelRecording]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_220,
                changedKeyCode: 59
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_250,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
    }

    func testPassiveFnCapsLockTransitionCancelsPendingGesture() {
        let manager = makeManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskAlphaShift],
                timestampMs: 1_050,
                changedKeyCode: 57
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlphaShift],
                timestampMs: 1_100,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow]
        )
    }

    func testPassiveFnTapRecoveryAndResetCannotDuplicateActions() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(
            manager.recoverFromDisabledTapForTesting(
                flags: [.maskSecondaryFn],
                triggerKeyPressed: true,
                timestampMs: 1_050
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])

        manager.suppressUntilReset()
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_200,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            []
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
        XCTAssertEqual(manager.holdWindowElapsedForTesting(), [])
    }

    func testDoubleTapOnlyGestureModeDoesNotStartHoldRecording() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapOnly)

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

    func testRecoverFromDisabledTapPreservesArmedHoldStartWhileTriggerHeld() {
        // Regression: holding Fn to start a new dictation in the ~1s window right
        // after a previous one pastes did nothing. The Instant-Dictation warm-mic
        // restart disables the CGEvent tap; on recovery (no active recording yet)
        // the manager hard-reset the gesture and cancelled the armed start, and
        // since Fn was still held no new edge re-armed it.
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)

        // Fresh Fn press arms the startup debounce; the start has not fired yet.
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )

        // Tap disabled + recovered while Fn is still physically held.
        manager.recoverFromDisabledTapForTesting(
            flags: [.maskSecondaryFn],
            triggerKeyPressed: true,
            timestampMs: 1_050
        )

        // The pending start must survive the recovery and still fire.
        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
    }

    func testRecoverFromDisabledTapStillResetsPendingStartWhenTriggerReleased() {
        // The preserve path is gated on the trigger still being held — if it was
        // released, recovery must still clear the stale pending start (no phantom).
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )

        manager.recoverFromDisabledTapForTesting(
            flags: [],
            triggerKeyPressed: false,
            timestampMs: 1_050
        )

        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
    }

    func testHoldOnlyGestureModeStartsAndStopsHoldRecording() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)

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
        let manager = makeManager(trigger: .fn, gestureMode: .singleTapToggle)

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
        let manager = makeManager(trigger: .command, gestureMode: .singleTapToggle)

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
        let manager = makeManager(trigger: .command, gestureMode: .holdOnly)

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
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)

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
        let manager = makeManager(trigger: trigger, gestureMode: .doubleTapOnly)

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
        let manager = makeManager(trigger: trigger, gestureMode: .holdOnly)

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
        let manager = makeManager(trigger: trigger, gestureMode: .singleTapToggle)

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
        let manager = makeManager(trigger: trigger, gestureMode: .holdOnly)

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
        let manager = makeManager(trigger: trigger, gestureMode: .singleTapToggle)

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
            let manager = makeManager(trigger: trigger, gestureMode: .singleTapToggle)

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

    func testControlBacktickChordStartsHandsFreeDictation() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 50)
        let manager = makeManager(trigger: trigger, gestureMode: .singleTapToggle)

        let keyDown = manager.chordEventDecisionForTesting(
            type: .keyDown,
            keyCode: 50,
            flags: trigger.chordEventFlags,
            timestampMs: 1_000
        )

        XCTAssertEqual(keyDown.outputs, [.startRecording(mode: .persistent)])
        XCTAssertTrue(keyDown.shouldSwallow)
    }

    func testDefaultFnSpaceChordCancelsPendingPushToTalkBeforeHandsFreeStarts() {
        let pushToTalk = HotkeyManager(
            trigger: .defaultPushToTalk,
            gestureMode: .holdOnly,
            startupDebounceMs: FnKeyStateMachine.defaultTapThresholdMs
        )
        pushToTalk.setPhysicalKeyStateProviderForTesting { _ in false }
        let handsFree = makeManager(trigger: .fnSpace, gestureMode: .singleTapToggle)

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
        let manager = makeManager(trigger: trigger, gestureMode: .holdOnly)

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
        let manager = makeManager(trigger: trigger, gestureMode: .singleTapToggle)

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
        let manager = makeManager(trigger: .fn)

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

    func testTapRecoveryPreservesPendingStartWhileModifierHeld() {
        // Counterpart to testTapRecoveryResetsPendingModifierGesture (which
        // recovers with the trigger released and resets). Here Fn is STILL held
        // through the recovery. Previously the manager reset and cancelled the
        // armed start even while held, so holding Fn right after a paste (when the
        // Instant-Dictation warm-mic restart disables the tap) did nothing until
        // the user released and re-pressed. Now the pending start is preserved and
        // still fires on the debounce.
        let manager = makeManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )

        // Tap disabled + recovered while Fn is still physically held.
        manager.recoverFromDisabledTapForTesting(flags: [.maskSecondaryFn])

        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )
    }

    func testTapRecoveryDuringActiveHoldToTalkStopsOnRelease() {
        let manager = makeManager(trigger: .fn)

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

    func testHoldToTalkStopTailDelaysStopCallback() {
        let manager = HotkeyManager(
            trigger: .fn,
            holdToTalkStopTailMs: 20
        )
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        var stopCount = 0
        let stopExpectation = expectation(description: "stop callback fires after tail")
        manager.onStopRecording = {
            stopCount += 1
            stopExpectation.fulfill()
        }

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
        XCTAssertEqual(stopCount, 0)
        manager.resetToIdle(flags: [])

        wait(for: [stopExpectation], timeout: 1.0)
        XCTAssertEqual(stopCount, 1)
    }

    /// Starting a take while the previous one finishes resets every hotkey
    /// after the take began. Syncing the recording mode must restore the held
    /// Fn so the release still stops the take.
    func testSyncAfterFlowResetKeepsHoldToTalkReleaseWorking() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapAndHold)
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

        manager.resetToIdle(flags: [.maskSecondaryFn])
        manager.syncRecordingMode(.holdToTalk, flags: [.maskSecondaryFn], triggerKeyPressed: false)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 2_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording]
        )
    }

    func testSyncAfterFlowResetStopsWhenTriggerAlreadyReleased() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapAndHold)
        var stops = 0
        manager.onStopRecording = { stops += 1 }
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

        // The release landed while the flow reset had cleared the gesture.
        manager.resetToIdle(flags: [])
        manager.syncRecordingMode(.holdToTalk, flags: [], triggerKeyPressed: false)
        XCTAssertEqual(stops, 1)
    }

    func testSyncWhileTriggerHeldLeavesNormalTakeUnchanged() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapAndHold)
        var stops = 0
        manager.onStopRecording = { stops += 1 }
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        manager.syncRecordingMode(.holdToTalk, flags: [.maskSecondaryFn], triggerKeyPressed: false)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 2_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            ),
            [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording]
        )
    }

    /// A take accepted with another modifier already held must still stop,
    /// not cancel, on release: the sync only restores state a reset lost.
    func testSyncDoesNotRejudgeAcceptedModifierTake() {
        let manager = makeManager(trigger: .option, gestureMode: .holdOnly)
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskShift], timestampMs: 900)
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskShift, .maskAlternate], timestampMs: 1_000)
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

        manager.syncRecordingMode(.holdToTalk, flags: [.maskShift, .maskAlternate], triggerKeyPressed: false)

        let release = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskShift], timestampMs: 2_000)
        XCTAssertTrue(release.contains(.stopRecording), "got \(release)")
        XCTAssertFalse(release.contains(.cancelRecording))
    }

    /// Bare Fn: a modifier pressed during the reset gap still contaminates
    /// the take, so releasing Fn with Shift held cancels.
    func testSyncAfterFlowResetKeepsFnContaminationFromTheGap() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapAndHold)
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

        manager.resetToIdle(flags: [.maskSecondaryFn])
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn, .maskShift], timestampMs: 1_500)
        manager.syncRecordingMode(.holdToTalk, flags: [.maskSecondaryFn, .maskShift], triggerKeyPressed: false)

        let release = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskShift],
            timestampMs: 2_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertTrue(release.contains(.cancelRecording), "got \(release)")
        XCTAssertFalse(release.contains(.stopRecording))
    }

    /// Fn released during the reset gap while Shift stays held: the missed
    /// release was not bare, so the take cancels instead of pasting.
    func testSyncAfterFlowResetCancelsWhenFnReleasedWithModifierHeld() {
        let manager = makeManager(trigger: .fn, gestureMode: .doubleTapAndHold)
        var stops = 0
        var cancels = 0
        manager.onStopRecording = { stops += 1 }
        manager.onCancelRecording = { cancels += 1 }
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000,
            changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

        manager.resetToIdle(flags: [.maskSecondaryFn])
        manager.syncRecordingMode(.holdToTalk, flags: [.maskShift], triggerKeyPressed: false)

        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(stops, 0)
    }

    /// A complete Shift tap during the reset gap, Fn held throughout, still
    /// contaminates the take, whether Fn is released before or after sync.
    func testSyncAfterFlowResetRemembersModifierTapFromTheGap() {
        for releaseBeforeSync in [false, true] {
            let manager = makeManager(trigger: .fn, gestureMode: .doubleTapAndHold)
            var stops = 0
            var cancels = 0
            manager.onStopRecording = { stops += 1 }
            manager.onCancelRecording = { cancels += 1 }
            _ = manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000,
                changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
            )
            XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

            manager.resetToIdle(flags: [.maskSecondaryFn])
            let fnShift = sideSpecificFlags(
                CGEventFlags.maskSecondaryFn.rawValue,
                CGEventFlags.maskShift.rawValue,
                leftShiftMask
            )
            _ = manager.modifierFlagsChangedOutputsForTesting(flags: fnShift, timestampMs: 1_400, changedKeyCode: 56)
            _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_450, changedKeyCode: 56)

            if releaseBeforeSync {
                _ = manager.modifierFlagsChangedOutputsForTesting(
                    flags: [],
                    timestampMs: 1_500,
                    changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
                )
                manager.syncRecordingMode(.holdToTalk, flags: [], triggerKeyPressed: false)
                XCTAssertEqual(cancels, 1, "released before sync")
            } else {
                manager.syncRecordingMode(.holdToTalk, flags: [.maskSecondaryFn], triggerKeyPressed: false)
                let release = manager.modifierFlagsChangedOutputsForTesting(
                    flags: [],
                    timestampMs: 2_000,
                    changedKeyCode: HotkeyTrigger.canonicalFnKeyCode
                )
                XCTAssertTrue(release.contains(.cancelRecording), "got \(release)")
            }
            XCTAssertEqual(stops, 0)
        }
    }

    func testSyncAfterFlowResetKeepsKeyCodeHoldReleaseWorking() {
        let manager = makeManager(trigger: HotkeyTrigger.fromKeyCode(105), gestureMode: .holdOnly)
        XCTAssertEqual(
            manager.keyCodeEventDecisionForTesting(type: .keyDown, keyCode: 105, timestampMs: 1_000).outputs,
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])

        manager.resetToIdle(flags: [])
        manager.syncRecordingMode(.holdToTalk, flags: [], triggerKeyPressed: true)

        let release = manager.keyCodeEventDecisionForTesting(type: .keyUp, keyCode: 105, timestampMs: 2_000)
        XCTAssertTrue(release.outputs.contains(.stopRecording), "got \(release.outputs)")
    }

    /// Startup can finish during the stop tail; the sync must not restart it.
    func testSyncDuringPendingStopTailKeepsTheOriginalTail() {
        let manager = HotkeyManager(trigger: .fn, holdToTalkStopTailMs: 50)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        var pending = 0
        var cancelled = 0
        let stopped = expectation(description: "one stop")
        manager.onStopPending = { pending += 1 }
        manager.onStopPendingCancelled = { cancelled += 1 }
        manager.onStopRecording = { stopped.fulfill() }

        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000)
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        _ = manager.recoverFromDisabledTapForTesting(flags: [], timestampMs: 1_500)
        XCTAssertEqual(pending, 1)

        manager.syncRecordingMode(.holdToTalk, flags: [], triggerKeyPressed: false)
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(cancelled, 0)
        wait(for: [stopped], timeout: 1.0)
    }

    func testStopTailSignalsPendingThenStops() {
        let manager = HotkeyManager(trigger: .fn, holdToTalkStopTailMs: 20)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        var pending = 0
        var cancelled = 0
        let stopped = expectation(description: "stop after tail")
        manager.onStopPending = { pending += 1 }
        manager.onStopPendingCancelled = { cancelled += 1 }
        manager.onStopRecording = {
            XCTAssertEqual(pending, 1, "the UI hears about the release before the stop")
            stopped.fulfill()
        }

        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000)
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        _ = manager.recoverFromDisabledTapForTesting(flags: [], timestampMs: 1_500)
        XCTAssertEqual(pending, 1)

        wait(for: [stopped], timeout: 1.0)
        XCTAssertEqual(cancelled, 0)
    }

    func testAbandonedStopTailSignalsPendingCancelled() {
        let manager = HotkeyManager(trigger: .fn, holdToTalkStopTailMs: 50)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        var pending = 0
        var cancelled = 0
        manager.onStopPending = { pending += 1 }
        manager.onStopPendingCancelled = { cancelled += 1 }
        manager.onStopRecording = { XCTFail("an abandoned tail must not stop") }

        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000)
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        _ = manager.recoverFromDisabledTapForTesting(flags: [], timestampMs: 1_500)
        XCTAssertEqual(pending, 1)

        manager.suppressUntilReset()
        XCTAssertEqual(cancelled, 1)
        manager.suppressUntilReset()
        XCTAssertEqual(cancelled, 1, "only a pending tail reports cancellation")

        let settle = expectation(description: "tail window passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)
    }

    /// Some app posted a keyDown without its keyUp, so the session snapshot
    /// reports the key held forever. Once the tap sees that key released,
    /// bare Fn is admitted again.
    func testPassiveFnIgnoresSnapshotKeyTheTapSawReleased() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { $0 == 9 }

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000),
            [],
            "a snapshot-held key still blocks Fn"
        )
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_100)

        _ = manager.modifierKeyDownOutputsForTesting(keyCode: 9, timestampMs: 1_200)
        _ = manager.modifierKeyUpOutputsForTesting(keyCode: 9, timestampMs: 1_300)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 2_000),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
    }

    func testPassiveFnTrustsSnapshotAgainAfterKeyDownOrTapRecovery() {
        let manager = makeManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setPhysicalKeyStateProviderForTesting { $0 == 9 }

        _ = manager.modifierKeyUpOutputsForTesting(keyCode: 9, timestampMs: 1_000)
        _ = manager.modifierKeyDownOutputsForTesting(keyCode: 9, timestampMs: 1_100)
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_200),
            [],
            "a keyDown after the release means the key really is held"
        )
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_300)

        _ = manager.modifierKeyUpOutputsForTesting(keyCode: 9, timestampMs: 1_400)
        _ = manager.recoverFromDisabledTapForTesting(flags: [], timestampMs: 1_500)
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_600),
            [],
            "after a disabled tap, events may have been missed, so the snapshot counts again"
        )
    }

    func testTapRecoveryDuringActiveHoldWithAdditionalModifierCancelsOnRelease() {
        let manager = makeManager(trigger: .fn)

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
            [.cancelStartupDebounce, .cancelHoldWindow, .cancelRecording]
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_300
            ),
            []
        )
    }

    func testTapRecoveryDuringSideSpecificHoldWithOppositeSideCancelsOnRelease() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: .fn)

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
        let manager = makeManager(trigger: .fn)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: .fn)

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
        let manager = makeManager(trigger: .option, gestureMode: .holdOnly)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: .fn)

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
                timestampMs: 1_050,
                changedKeyCode: 59
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
        let manager = makeManager(trigger: .fn)

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
        let manager = makeManager(trigger: .fn)

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
        let manager = makeManager(trigger: .fn)

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
                timestampMs: 1_175,
                changedKeyCode: 59
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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger, gestureMode: .holdOnly)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: .option)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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
        let manager = makeManager(trigger: trigger)

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

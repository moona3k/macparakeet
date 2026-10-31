import CoreGraphics
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class SyntheticPasteHotkeyTests: XCTestCase {
    private func manager(session: Set<UInt16>, hid: Set<UInt16>) -> HotkeyManager {
        let manager = HotkeyManager(trigger: .fn, gestureMode: .holdOnly)
        manager.setKeyStateProvidersForTesting(session: { session.contains($0) }, hid: { hid.contains($0) })
        manager.setPhysicalFlagsProviderForTesting { [] }
        return manager
    }

    private func event(_ type: CGEventType, key: UInt16 = 9, marked: Bool = true) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type == .keyDown))
        event.type = type
        event.flags = []
        event.timestamp = 1_100_000_000
        if marked { AppGeneratedEventMarker.mark(event) }
        return event
    }

    func testStaleSessionKeyDoesNotBlockFreshManagersOrTapRecovery() {
        for _ in 0..<2 {  // No previous-process release ledger is supplied.
            let manager = manager(session: [9, 17], hid: [])
            for timestamp: UInt64 in [1_000, 2_000, 3_000] {
                _ = manager.recoverFromDisabledTapForTesting(flags: [], timestampMs: timestamp - 1)
                XCTAssertEqual(
                    manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: timestamp),
                    [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
                )
                _ = manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: timestamp + 100)
                manager.resetToIdle(flags: [])
            }
        }
    }

    func testHIDHeldKeysStillBlockEvenWhenSessionReportsUp() {
        for key: UInt16 in [9, 17, 54, 55] {
            let manager = manager(session: [], hid: [key])
            XCTAssertEqual(
                manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000), [])
        }
    }

    func testOwnReleaseCannotOverrideARealHeldKey() throws {
        let manager = manager(session: [9], hid: [9])
        XCTAssertFalse(manager.processEventForTesting(type: .keyUp, event: try event(.keyUp)))
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 2_000), [])
    }

    func testPreHeldUnmarkedSessionOnlyKeyDoesNotVetoFreshFn() throws {
        let manager = manager(session: [9], hid: [])
        XCTAssertFalse(manager.processEventForTesting(type: .keyDown, event: try event(.keyDown, marked: false)))
        // Event dispatch remains unmarked, but a fresh press reconciles held
        // ordinary keys from HID rather than retaining session-only input.
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 2_000),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
    }

    func testLegacyHIDStalenessKeepsObservedReleaseRecovery() {
        let manager = manager(session: [9], hid: [9])
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000), [])
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_100)
        _ = manager.modifierKeyUpOutputsForTesting(keyCode: 9, timestampMs: 1_200)
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 2_000),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 2_100)
        _ = manager.recoverFromDisabledTapForTesting(flags: [], timestampMs: 2_200)
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 3_000), [])
    }

    func testClearingContaminationCannotResurrectTheSameFnPress() {
        let manager = manager(session: [9], hid: [9])
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000), [])
        manager.setKeyStateProvidersForTesting(session: { $0 == 9 }, hid: { _ in false })
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_100), [])
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_200), [])
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 2_000),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
    }

    func testMarkedPairOrMissingReleaseCannotInterruptAnOwnedTake() throws {
        let manager = manager(session: [9], hid: [])
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000)
        XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        var cancelled = 0
        manager.onCancelRecording = { cancelled += 1 }
        manager.onDiscardRecording = { _ in cancelled += 1 }
        manager.onStopRecording = { XCTFail("synthetic input must not stop the take") }
        // Repeated down, a missing-up interval, and a delayed up all stay output.
        for type: CGEventType in [.keyDown, .keyDown, .keyUp] {
            XCTAssertFalse(manager.processEventForTesting(type: type, event: try event(type)))
        }
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 2_000),
            [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording]
        )
    }

    func testUnmarkedTypingStillInterrupts() throws {
        let manager = manager(session: [], hid: [])
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000)
        _ = manager.startupDebounceElapsedForTesting()
        var interrupted = 0
        manager.onCancelRecording = { interrupted += 1 }
        manager.onDiscardRecording = { _ in interrupted += 1 }
        manager.processEventForTesting(type: .keyDown, event: try event(.keyDown, marked: false))
        XCTAssertEqual(interrupted, 1)
    }

    func testOwnOutputCannotInterruptOwnerOrTriggerPeerInEitherCallbackOrder() throws {
        for reverse in [false, true] {
            let owner = manager(session: [9], hid: [])
            let peer = HotkeyManager(
                trigger: HotkeyTrigger(kind: .keyCode, modifierName: nil, keyCode: 9), gestureMode: .singleTapToggle)
            owner.onCancelRecording = { XCTFail("output must not cancel owner") }
            owner.onDiscardRecording = { _ in XCTFail("output must not discard owner") }
            peer.onStartRecording = { _ in XCTFail("output must not trigger peer") }
            _ = owner.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000)
            XCTAssertEqual(owner.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
            let listeners = reverse ? [peer, owner] : [owner, peer]
            for type: CGEventType in [.keyDown, .keyUp] {
                let input = try event(type)
                for listener in listeners {
                    XCTAssertFalse(listener.processEventForTesting(type: type, event: input))
                }
            }
            XCTAssertEqual(
                owner.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 2_000),
                [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording])
            XCTAssertEqual(owner.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 2_100), [])
        }
    }

    func testTapRecoveryKeepsSessionHeldPeerClaimWhenHIDReportsUp() {
        let owner = HotkeyManager(
            trigger: .fn, gestureMode: .holdOnly,
            peerTriggers: [HotkeyTrigger(kind: .keyCode, modifierName: nil, keyCode: 9)])
        owner.setKeyStateProvidersForTesting(session: { $0 == 9 }, hid: { _ in false })
        owner.setPhysicalFlagsProviderForTesting { [] }
        owner.onCancelRecording = { XCTFail("peer release must not cancel owner") }
        owner.onDiscardRecording = { _ in XCTFail("peer release must not discard owner") }
        owner.onStopRecording = { XCTFail("recovery with Fn held must not stop owner") }
        _ = owner.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000)
        XCTAssertEqual(owner.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(
            owner.modifierKeyDownOutputsForTesting(keyCode: 9, timestampMs: 1_100, flags: [.maskSecondaryFn]), [])
        XCTAssertEqual(owner.recoverFromDisabledTapForTesting(flags: [.maskSecondaryFn], timestampMs: 1_200), [])
        XCTAssertEqual(owner.modifierKeyUpOutputsForTesting(keyCode: 9, timestampMs: 1_300), [])
        XCTAssertEqual(
            owner.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 2_000),
            [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording])
    }

    func testAuxiliaryAndTransformListenersIgnoreOwnOutputAndStillAcceptUnmarkedInput() throws {
        let auxiliary = GlobalShortcutManager(trigger: HotkeyTrigger(kind: .keyCode, modifierName: nil, keyCode: 9))
        let transforms = TransformsHotkeyRegistry()
        transforms.register(
            promptID: UUID(),
            shortcut: KeyboardShortcut(
                modifiers: KeyboardShortcut.ModifierFlag.command.rawValue, keyCode: 9, keyLabel: "V"))
        var auxiliaryTriggers = 0
        var transformTriggers = 0
        auxiliary.onTrigger = { auxiliaryTriggers += 1 }
        transforms.onTrigger = { _ in transformTriggers += 1 }
        for type: CGEventType in [.keyDown, .keyUp] {
            let input = try event(type)
            input.flags = .maskCommand
            XCTAssertNotNil(auxiliary.handleEvent(type: type, event: input))
            XCTAssertNotNil(transforms.handleEvent(type: type, event: input))
        }
        XCTAssertEqual(auxiliaryTriggers, 0)
        XCTAssertEqual(transformTriggers, 0)
        let input = try event(.keyDown, marked: false)
        input.flags = .maskCommand
        _ = auxiliary.handleEvent(type: .keyDown, event: input)
        _ = transforms.handleEvent(type: .keyDown, event: input)
        XCTAssertEqual(auxiliaryTriggers, 1)
        XCTAssertEqual(transformTriggers, 1)
    }

    func testMarkedEventsCannotTriggerOrBeSwallowedByCustomShortcut() throws {
        let manager = HotkeyManager(
            trigger: HotkeyTrigger(kind: .keyCode, modifierName: nil, keyCode: 9), gestureMode: .singleTapToggle)
        manager.onStartRecording = { _ in XCTFail("own output cannot trigger a shortcut") }
        for type: CGEventType in [.keyDown, .keyUp] {
            XCTAssertFalse(manager.processEventForTesting(type: type, event: try event(type)))
        }
    }
}

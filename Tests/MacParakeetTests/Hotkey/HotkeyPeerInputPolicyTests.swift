import IOKit.hidsystem
import XCTest
import MacParakeetCore
@testable import MacParakeet

final class HotkeyPeerInputPolicyTests: XCTestCase {
    private let option = CGEventFlags.maskAlternate.rawValue
    private let leftOption = CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))
    private let rightOption = CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))
    private let rightOptionTrigger = HotkeyTrigger(
        kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)

    func testKeyTriggerIsClaimedWhateverModifiersAreHeld() {
        let policy = HotkeyPeerInputPolicy(peers: [.fromKeyCode(117)])
        XCTAssertTrue(policy.claimsKey(117, flags: 0))
        XCTAssertTrue(policy.claimsKey(117, flags: CGEventFlags.maskControl.rawValue))
        XCTAssertFalse(policy.claimsKey(118, flags: 0))
        XCTAssertTrue(policy.claimsKeys)
    }

    func testChordTerminalKeyIsClaimedOnlyWithItsModifiersHeld() {
        let policy = HotkeyPeerInputPolicy(peers: [.chord(modifiers: ["option"], keyCode: 119)])
        XCTAssertTrue(policy.claimsKey(119, flags: option))
        XCTAssertTrue(
            policy.claimsKey(119, flags: option | CGEventFlags.maskControl.rawValue),
            "Held modifiers beyond the chord's are tolerated, as for the chord's own manager")
        XCTAssertFalse(policy.claimsKey(119, flags: 0), "The terminal key alone is typing")
        XCTAssertFalse(policy.claimsKey(119, flags: CGEventFlags.maskControl.rawValue))
        XCTAssertFalse(policy.claimsKey(120, flags: option), "Another key under the prefix is typing")
    }

    func testFnKeyCodesAreClaimedOnlyWhenFnIsAPeer() {
        for keyCode in [UInt16(63), 179] {
            XCTAssertTrue(HotkeyPeerInputPolicy(peers: [.fn]).claimsKey(keyCode, flags: 0))
            XCTAssertTrue(
                HotkeyPeerInputPolicy(peers: [.chord(modifiers: ["fn"], keyCode: 49)]).claimsKey(keyCode, flags: 0))
            XCTAssertFalse(HotkeyPeerInputPolicy(peers: [.option]).claimsKey(keyCode, flags: 0))
            XCTAssertFalse(HotkeyPeerInputPolicy.none.claimsKey(keyCode, flags: 0))
        }
    }

    func testDisabledPeersClaimNothing() {
        let policy = HotkeyPeerInputPolicy(peers: [.disabled])
        XCTAssertEqual(policy, .none)
        XCTAssertFalse(policy.claimsKeys)
        XCTAssertEqual(policy.claimedModifierFlags(in: [.maskAlternate], excluding: []), [])
    }

    func testGenericModifierPeerClaimsEitherSide() {
        let policy = HotkeyPeerInputPolicy(peers: [.option])
        for side in [leftOption, rightOption, []] as [CGEventFlags] {
            XCTAssertEqual(
                policy.claimedModifierFlags(in: [.maskControl, .maskAlternate, side], excluding: .maskControl),
                .maskAlternate)
        }
    }

    func testSideSpecificPeerClaimsOnlyItsOwnSide() {
        let policy = HotkeyPeerInputPolicy(peers: [rightOptionTrigger])
        XCTAssertEqual(
            policy.claimedModifierFlags(in: [.maskAlternate, rightOption], excluding: []), .maskAlternate)
        XCTAssertEqual(
            policy.claimedModifierFlags(in: [.maskAlternate, leftOption], excluding: []), [],
            "The opposite side is not the configured shortcut")
        XCTAssertEqual(
            policy.claimedModifierFlags(in: [.maskAlternate, leftOption, rightOption], excluding: []), [],
            "A modifier also held by an unconfigured side is not peer-only")
        XCTAssertEqual(
            policy.claimedModifierFlags(in: [.maskAlternate], excluding: []), [],
            "Without side bits the pressed side is unknown")
        XCTAssertTrue(policy.claimsModifierKeyCode(61))
        XCTAssertFalse(policy.claimsModifierKeyCode(58))
    }

    func testChordPrefixAndModifierChordComponentsAreClaimed() {
        let policy = HotkeyPeerInputPolicy(peers: [
            .chord(modifiers: ["option"], keyCode: 119),
            .modifierChord(modifiers: ["shift", "command"]),
        ])
        let all: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        XCTAssertEqual(
            policy.claimedModifierFlags(in: all, excluding: []), [.maskAlternate, .maskShift, .maskCommand])
        for keyCode in [UInt16(58), 61, 56, 60, 55, 54] {
            XCTAssertTrue(policy.claimsModifierKeyCode(keyCode), "\(keyCode)")
        }
        XCTAssertFalse(policy.claimsModifierKeyCode(59), "Control is not configured")
    }

    func testOwnersOwnModifierIsNeverClaimed() {
        let policy = HotkeyPeerInputPolicy(peers: [.chord(modifiers: ["control", "option"], keyCode: 119)])
        XCTAssertEqual(
            policy.claimedModifierFlags(in: [.maskControl, .maskAlternate], excluding: .maskControl),
            .maskAlternate)
    }

    func testKeyUpIsWatchedOnlyWhenAPeerKeyNeedsIt() {
        let keyUp: CGEventMask = 1 << CGEventType.keyUp.rawValue
        XCTAssertEqual(
            HotkeyManager.eventMask(for: .control, peerInput: HotkeyPeerInputPolicy(peers: [.fromKeyCode(117)]))
                & keyUp,
            keyUp)
        XCTAssertEqual(
            HotkeyManager.eventMask(
                for: .control,
                peerInput: HotkeyPeerInputPolicy(peers: [.chord(modifiers: ["option"], keyCode: 119)])) & keyUp,
            keyUp)
        XCTAssertEqual(
            HotkeyManager.eventMask(
                for: .control, peerInput: HotkeyPeerInputPolicy(peers: [.option, .fn])) & keyUp,
            0)
        XCTAssertEqual(HotkeyManager.eventMask(for: .control) & keyUp, 0)
    }
}

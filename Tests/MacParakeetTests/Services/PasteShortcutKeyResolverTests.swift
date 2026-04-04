import Carbon
import XCTest
@testable import MacParakeetCore

final class PasteShortcutKeyResolverTests: XCTestCase {
    func testResolvesNonQwertyMapping() {
        let resolver = PasteShortcutKeyResolver(
            keyboardLayoutProvider: { .data(Self.dummyLayoutData) },
            keyboardTypeProvider: { 40 },
            translatedCharacterProvider: { _, keyCode, modifierKeyState, keyboardType in
                XCTAssertEqual(modifierKeyState, 0)
                XCTAssertEqual(keyboardType, 40)
                return keyCode == 17 ? Self.vCharacter : nil
            }
        )

        XCTAssertEqual(resolver.virtualKeyCode(for: "v"), 17)
    }

    func testUsesCommandModifiedMappingWhenResolvingPasteShortcut() {
        let commandModifierState = UInt32(cmdKey >> 8)
        let resolver = PasteShortcutKeyResolver(
            keyboardLayoutProvider: { .data(Self.dummyLayoutData) },
            translatedCharacterProvider: { _, keyCode, modifierKeyState, _ in
                switch (keyCode, modifierKeyState) {
                case (9, commandModifierState):
                    return Self.vCharacter
                case (17, 0):
                    return Self.vCharacter
                default:
                    return nil
                }
            }
        )

        XCTAssertEqual(resolver.virtualKeyCode(for: "v", modifierKeyState: 0), 17)
        XCTAssertEqual(resolver.virtualKeyCode(for: "v", modifierKeyState: commandModifierState), 9)
    }

    func testFallsBackToQwertyWhenLayoutSourceIsMissing() {
        let resolver = PasteShortcutKeyResolver(
            keyboardLayoutProvider: { .missingInputSource },
            translatedCharacterProvider: { _, _, _, _ in
                XCTFail("Translator should not be called when input source is missing")
                return nil
            }
        )

        XCTAssertEqual(resolver.virtualKeyCode(for: "v"), 0x09)
    }

    func testFallsBackToQwertyWhenLayoutDataIsMissing() {
        let resolver = PasteShortcutKeyResolver(
            keyboardLayoutProvider: { .missingLayoutData },
            translatedCharacterProvider: { _, _, _, _ in
                XCTFail("Translator should not be called when layout data is missing")
                return nil
            }
        )

        XCTAssertEqual(resolver.virtualKeyCode(for: "v"), 0x09)
    }

    func testFallsBackToQwertyWhenNoMatchingKeyCodeExists() {
        let resolver = PasteShortcutKeyResolver(
            keyboardLayoutProvider: { .data(Self.dummyLayoutData) },
            translatedCharacterProvider: { _, _, _, _ in nil }
        )

        XCTAssertEqual(resolver.virtualKeyCode(for: "v"), 0x09)
    }

    private static let dummyLayoutData = Data([0x00]) as CFData
    private static let vCharacter = UniChar(("v" as UnicodeScalar).value)
}

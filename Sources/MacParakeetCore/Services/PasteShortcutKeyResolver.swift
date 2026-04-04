import Carbon
import Foundation
import OSLog

enum KeyboardLayoutLookupResult {
    case data(CFData)
    case missingInputSource
    case missingLayoutData
    case inaccessibleLayoutBytes
}

struct PasteShortcutKeyResolver {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "ClipboardService")
    private let keyboardLayoutProvider: () -> KeyboardLayoutLookupResult
    private let keyboardTypeProvider: () -> UInt32
    private let translatedCharacterProvider: (CFData, UInt16, UInt32, UInt32) -> UniChar?

    init(
        keyboardLayoutProvider: @escaping () -> KeyboardLayoutLookupResult = Self.liveKeyboardLayout,
        keyboardTypeProvider: @escaping () -> UInt32 = { UInt32(LMGetKbdType()) },
        translatedCharacterProvider: @escaping (CFData, UInt16, UInt32, UInt32) -> UniChar? = Self.translatedCharacter
    ) {
        self.keyboardLayoutProvider = keyboardLayoutProvider
        self.keyboardTypeProvider = keyboardTypeProvider
        self.translatedCharacterProvider = translatedCharacterProvider
    }

    func virtualKeyCode(for character: Character, modifierKeyState: UInt32 = 0) -> CGKeyCode {
        let fallbackKeyCode: CGKeyCode = 0x09
        let layoutLookup = keyboardLayoutProvider()

        let layoutData: CFData
        switch layoutLookup {
        case .data(let data):
            layoutData = data
        case .missingInputSource:
            logger.error("Failed to get current keyboard input source; falling back to QWERTY keycode 0x09")
            return fallbackKeyCode
        case .missingLayoutData:
            logger.error("Failed to resolve keyboard layout data for paste shortcut; falling back to QWERTY keycode 0x09")
            return fallbackKeyCode
        case .inaccessibleLayoutBytes:
            logger.error("Failed to access keyboard layout bytes for paste shortcut; falling back to QWERTY keycode 0x09")
            return fallbackKeyCode
        }

        guard let target = String(character).utf16.first else {
            logger.error("Failed to encode character for paste shortcut lookup; falling back to QWERTY keycode 0x09")
            return fallbackKeyCode
        }

        let keyboardType = keyboardTypeProvider()
        for keyCode: UInt16 in 0..<128 {
            guard let translated = translatedCharacterProvider(layoutData, keyCode, modifierKeyState, keyboardType) else {
                continue
            }

            if translated == target {
                return CGKeyCode(keyCode)
            }
        }

        logger.error("Failed to resolve virtual keycode for character '\(String(character), privacy: .public)'; falling back to QWERTY keycode 0x09")
        return fallbackKeyCode
    }

    private static func liveKeyboardLayout() -> KeyboardLayoutLookupResult {
        guard let layoutSourceRef = TISCopyCurrentKeyboardLayoutInputSource() else {
            return .missingInputSource
        }
        let layoutSource = layoutSourceRef.takeRetainedValue()

        guard let layoutDataRef = TISGetInputSourceProperty(layoutSource, kTISPropertyUnicodeKeyLayoutData) else {
            return .missingLayoutData
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataRef).takeUnretainedValue()
        guard CFDataGetBytePtr(layoutData) != nil else {
            return .inaccessibleLayoutBytes
        }

        return .data(layoutData)
    }

    private static func translatedCharacter(
        layoutData: CFData,
        keyCode: UInt16,
        modifierKeyState: UInt32,
        keyboardType: UInt32
    ) -> UniChar? {
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let keyboardLayout = UnsafeRawPointer(layoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifierKeyState,
            keyboardType,
            UInt32(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else {
            return nil
        }

        return chars[0]
    }
}

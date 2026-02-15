@preconcurrency import ApplicationServices
import XCTest
@testable import MacParakeetCore

final class AccessibilityServiceTests: XCTestCase {
    func testNotAuthorizedThrows() throws {
        let backend = MockAccessibilityBackend(isTrusted: false)
        let service = AccessibilityService(defaultMaxCharacters: 16000, backend: backend)

        XCTAssertThrowsError(try service.getSelectedText()) { error in
            XCTAssertEqual(error as? AccessibilityServiceError, .notAuthorized)
        }
    }

    func testNoFocusedElementThrows() throws {
        let backend = MockAccessibilityBackend(
            isTrusted: true,
            focusedElement: nil
        )
        let service = AccessibilityService(defaultMaxCharacters: 16000, backend: backend)

        XCTAssertThrowsError(try service.getSelectedText()) { error in
            XCTAssertEqual(error as? AccessibilityServiceError, .noFocusedElement)
        }
    }

    func testDirectSelectedTextWins() throws {
        let backend = MockAccessibilityBackend(
            isTrusted: true,
            selectedText: "  Hello world  "
        )
        let service = AccessibilityService(defaultMaxCharacters: 16000, backend: backend)

        let selected = try service.getSelectedText()
        XCTAssertEqual(selected, "Hello world")
    }

    func testSelectedRangeFallbackUsesParameterizedString() throws {
        let backend = MockAccessibilityBackend(
            isTrusted: true,
            selectedText: nil,
            selectedRange: CFRange(location: 2, length: 5),
            stringForRange: "Hello"
        )
        let service = AccessibilityService(defaultMaxCharacters: 16000, backend: backend)

        let selected = try service.getSelectedText()
        XCTAssertEqual(selected, "Hello")
    }

    func testSelectedRangeFallbackUsesValueSubstring() throws {
        let backend = MockAccessibilityBackend(
            isTrusted: true,
            selectedText: nil,
            selectedRange: CFRange(location: 6, length: 5),
            stringForRange: nil,
            fullValue: "Hello world"
        )
        let service = AccessibilityService(defaultMaxCharacters: 16000, backend: backend)

        let selected = try service.getSelectedText()
        XCTAssertEqual(selected, "world")
    }

    func testZeroLengthRangeThrowsNoSelectedText() throws {
        let backend = MockAccessibilityBackend(
            isTrusted: true,
            selectedText: nil,
            selectedRange: CFRange(location: 0, length: 0)
        )
        let service = AccessibilityService(defaultMaxCharacters: 16000, backend: backend)

        XCTAssertThrowsError(try service.getSelectedText()) { error in
            XCTAssertEqual(error as? AccessibilityServiceError, .noSelectedText)
        }
    }

    func testUnsupportedWhenNoRangeAndNoSelectedText() throws {
        let backend = MockAccessibilityBackend(
            isTrusted: true,
            selectedText: nil,
            selectedRange: nil
        )
        let service = AccessibilityService(defaultMaxCharacters: 16000, backend: backend)

        XCTAssertThrowsError(try service.getSelectedText()) { error in
            XCTAssertEqual(error as? AccessibilityServiceError, .unsupportedElement)
        }
    }

    func testTextTooLongThrows() throws {
        let backend = MockAccessibilityBackend(
            isTrusted: true,
            selectedText: "abcdef"
        )
        let service = AccessibilityService(defaultMaxCharacters: 16000, backend: backend)

        XCTAssertThrowsError(try service.getSelectedText(maxCharacters: 5)) { error in
            XCTAssertEqual(error as? AccessibilityServiceError, .textTooLong(max: 5, actual: 6))
        }
    }
}

private struct MockAccessibilityBackend: AccessibilityBackend {
    let isTrustedValue: Bool
    let hasFocusedElement: Bool
    let selectedTextValue: String?
    let selectedRangeValue: CFRange?
    let fullValueValue: String?
    let stringForRangeValue: String?

    init(
        isTrusted: Bool,
        focusedElement: AXUIElement? = AXUIElementCreateSystemWide(),
        selectedText: String? = nil,
        selectedRange: CFRange? = nil,
        stringForRange: String? = nil,
        fullValue: String? = nil
    ) {
        self.isTrustedValue = isTrusted
        self.hasFocusedElement = focusedElement != nil
        self.selectedTextValue = selectedText
        self.selectedRangeValue = selectedRange
        self.fullValueValue = fullValue
        self.stringForRangeValue = stringForRange
    }

    func isTrusted() -> Bool { isTrustedValue }
    func focusedElement() -> AXUIElement? {
        hasFocusedElement ? AXUIElementCreateSystemWide() : nil
    }
    func selectedText(of element: AXUIElement) -> String? { selectedTextValue }
    func selectedRange(of element: AXUIElement) -> CFRange? { selectedRangeValue }
    func fullValue(of element: AXUIElement) -> String? { fullValueValue }
    func string(for range: CFRange, of element: AXUIElement) -> String? { stringForRangeValue }
}

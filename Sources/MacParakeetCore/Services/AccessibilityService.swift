import ApplicationServices
import Foundation

public protocol AccessibilityServiceProtocol: Sendable {
    func getSelectedText(maxCharacters: Int?) throws -> String
}

public extension AccessibilityServiceProtocol {
    func getSelectedText() throws -> String {
        try getSelectedText(maxCharacters: nil)
    }
}

public enum AccessibilityServiceError: Error, LocalizedError, Equatable {
    case notAuthorized
    case noFocusedElement
    case noSelectedText
    case textTooLong(max: Int, actual: Int)
    case unsupportedElement

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Accessibility permission is required to read selected text."
        case .noFocusedElement:
            return "No focused text field was found."
        case .noSelectedText:
            return "Select text first."
        case .textTooLong(let max, let actual):
            return "Selection is too long (\(actual) chars). Maximum is \(max)."
        case .unsupportedElement:
            return "The focused element does not expose selected text."
        }
    }
}

protocol AccessibilityBackend: Sendable {
    func isTrusted() -> Bool
    func focusedElement() -> AXUIElement?
    func selectedText(of element: AXUIElement) -> String?
    func selectedRange(of element: AXUIElement) -> CFRange?
    func fullValue(of element: AXUIElement) -> String?
    func string(for range: CFRange, of element: AXUIElement) -> String?
}

struct SystemAccessibilityBackend: AccessibilityBackend {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func focusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        guard let value = copyAttributeValue(
            element: systemElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func selectedText(of element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(
            element: element,
            attribute: kAXSelectedTextAttribute as CFString
        ) else {
            return nil
        }
        return value as? String
    }

    func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = copyAttributeValue(
            element: element,
            attribute: kAXSelectedTextRangeAttribute as CFString
        ) else {
            return nil
        }

        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    func fullValue(of element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(
            element: element,
            attribute: kAXValueAttribute as CFString
        ) else {
            return nil
        }
        return value as? String
    }

    func string(for range: CFRange, of element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var raw: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &raw
        )
        guard status == .success, let raw else {
            return nil
        }
        return raw as? String
    }

    private func copyAttributeValue(element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else {
            return nil
        }
        return value
    }
}

public final class AccessibilityService: AccessibilityServiceProtocol, @unchecked Sendable {
    private let backend: any AccessibilityBackend
    private let defaultMaxCharacters: Int

    public init(defaultMaxCharacters: Int = 16_000) {
        self.defaultMaxCharacters = defaultMaxCharacters
        self.backend = SystemAccessibilityBackend()
    }

    init(
        defaultMaxCharacters: Int = 16_000,
        backend: any AccessibilityBackend
    ) {
        self.defaultMaxCharacters = defaultMaxCharacters
        self.backend = backend
    }

    public func getSelectedText(maxCharacters: Int?) throws -> String {
        let max = maxCharacters ?? defaultMaxCharacters
        guard backend.isTrusted() else {
            throw AccessibilityServiceError.notAuthorized
        }
        guard let element = backend.focusedElement() else {
            throw AccessibilityServiceError.noFocusedElement
        }

        if let direct = normalized(backend.selectedText(of: element)), !direct.isEmpty {
            return try validatedLength(direct, max: max)
        }

        guard let range = backend.selectedRange(of: element) else {
            throw AccessibilityServiceError.unsupportedElement
        }
        guard range.length > 0 else {
            throw AccessibilityServiceError.noSelectedText
        }

        if let parameterized = normalized(backend.string(for: range, of: element)), !parameterized.isEmpty {
            return try validatedLength(parameterized, max: max)
        }

        guard let value = backend.fullValue(of: element) else {
            throw AccessibilityServiceError.unsupportedElement
        }

        let ns = value as NSString
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location >= 0,
              nsRange.length >= 0,
              nsRange.location + nsRange.length <= ns.length else {
            throw AccessibilityServiceError.unsupportedElement
        }

        guard let extracted = normalized(ns.substring(with: nsRange)), !extracted.isEmpty else {
            throw AccessibilityServiceError.noSelectedText
        }
        return try validatedLength(extracted, max: max)
    }

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validatedLength(_ text: String, max: Int) throws -> String {
        if text.count > max {
            throw AccessibilityServiceError.textTooLong(max: max, actual: text.count)
        }
        return text
    }
}

import CoreGraphics

/// Identifies our own automation at input listeners. This is an ownership
/// convention, not proof of hardware origin or a security boundary.
public enum AppGeneratedEventMarker {
    // Preserve the existing streaming marker for in-flight events and callers.
    public static let userData: Int64 = 0x4D50_5343

    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: userData)
    }

    public static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == userData
    }
}

/// Compatibility name for existing streaming/Voice Control integrations.
public typealias StreamingCursorEventMarker = AppGeneratedEventMarker

/// Inject application keyboard output downstream of the HID state table.
/// Posting at the HID entry point contaminates that table regardless of the
/// source state ID (#1286). Session posting still reaches the destination app.
enum AppGeneratedKeyboardEvents {
    static let postingLocation: CGEventTapLocation = .cgSessionEventTap

    static func makeSource() -> CGEventSource? {
        CGEventSource(stateID: .combinedSessionState)
    }

    static func makeEvent(
        source: CGEventSource, keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags
    ) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return nil
        }
        event.flags = flags
        AppGeneratedEventMarker.mark(event)
        return event
    }
}

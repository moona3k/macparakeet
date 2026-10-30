import CoreGraphics
import Foundation

/// Shared teardown for `CGEvent` taps.
///
/// Disabling a tap and removing its run-loop source does not release the
/// window-server connection; the Mach port must also be invalidated
/// (see `CFMachPort` docs). Without this, every stop/restart cycle leaves a
/// disabled tap registered for the process (#1132).
///
/// Call this before releasing the callback's retained `userInfo`, so no
/// callback can observe a released context.
public enum EventTapTeardown {
    public static func tearDown(
        tap: CFMachPort?,
        source: CFRunLoopSource?,
        runLoop: CFRunLoop?
    ) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
    }
}

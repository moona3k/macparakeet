import CoreGraphics
import Foundation
import XCTest

@testable import MacParakeetCore

final class BackgroundEventTapTests: XCTestCase {
    func testPerformAndWaitRunsOnTapThreadAndNestsInline() {
        let thread = EventTapThread.shared
        let (onTapThread, nestedOnTapThread, isMain) = thread.performAndWait {
            let nested = thread.performAndWait { thread.isCurrent }
            return (thread.isCurrent, nested, Thread.isMainThread)
        }

        XCTAssertTrue(onTapThread)
        XCTAssertTrue(nestedOnTapThread)
        XCTAssertFalse(isMain)
        XCTAssertFalse(thread.isCurrent)
    }

    /// The run loop can release a performed block after the caller resumes.
    /// A block that captured the non-escaping body tripped
    /// `withoutActuallyEscaping`'s runtime check about one run in five.
    func testPerformAndWaitNeverLeaksBodyPastReturn() {
        let thread = EventTapThread.shared
        var total = 0
        for value in 0..<5_000 {
            total += thread.performAndWait { value }
        }
        XCTAssertEqual(total, (0..<5_000).reduce(0, +))
    }

    /// The #1142 acceptance check: with the main thread blocked for 500 ms,
    /// tap callbacks still run promptly. Listen-only, and the only event
    /// posted is a marked mouse move to the pointer's current position, so the
    /// user's input is untouched. Skips where tap creation is denied (CI).
    func testCallbacksRunWhileMainThreadIsBlocked() throws {
        XCTAssertTrue(Thread.isMainThread)
        let marker: Int64 = 0x4D50_3131
        let received = LockedEvents()
        guard let tap = BackgroundEventTap.start(
            options: .listenOnly,
            eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue,
            handler: { _, event in
                if event.getIntegerValueField(.eventSourceUserData) == marker {
                    received.append(onTapThread: EventTapThread.shared.isCurrent, at: DispatchTime.now())
                }
                return Unmanaged.passUnretained(event)
            }
        ) else {
            throw XCTSkip("Event tap creation needs Input Monitoring permission")
        }
        defer { tap.stop() }

        let postedAt = LockedTime()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(100)) {
            guard let location = CGEvent(source: nil)?.location,
                let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: location,
                    mouseButton: .left
                )
            else { return }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            postedAt.set(DispatchTime.now())
            event.post(tap: .cgSessionEventTap)
        }

        let stallStart = DispatchTime.now()
        Thread.sleep(forTimeInterval: 0.5)
        let stallEnd = DispatchTime.now()

        let first = try XCTUnwrap(received.first, "no callback during the main-thread stall")
        XCTAssertTrue(first.onTapThread)
        XCTAssertGreaterThan(first.at.uptimeNanoseconds, stallStart.uptimeNanoseconds)
        XCTAssertLessThan(first.at.uptimeNanoseconds, stallEnd.uptimeNanoseconds, "callback waited for the main thread")
        let posted = try XCTUnwrap(postedAt.value)
        let latencyMs = Double(first.at.uptimeNanoseconds - posted.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(latencyMs, 100)
    }

    func testStartStopCyclesDoNotAccumulateTaps() throws {
        let baseline = try XCTUnwrap(eventTapCountForThisProcess())
        for _ in 0..<10 {
            guard let tap = BackgroundEventTap.start(
                options: .listenOnly,
                eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
                handler: { _, event in Unmanaged.passUnretained(event) }
            ) else {
                throw XCTSkip("Event tap creation needs Input Monitoring permission")
            }
            let source = try XCTUnwrap(tap.runLoopSourceForTesting)
            XCTAssertTrue(CFRunLoopContainsSource(EventTapThread.shared.runLoop, source, .commonModes))
            XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
            tap.stop()
            tap.stop()
            XCTAssertNil(tap.runLoopSourceForTesting)
        }
        XCTAssertEqual(eventTapCountForThisProcess(), baseline)
    }
}

func eventTapCountForThisProcess() -> Int? {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    guard CGGetEventTapList(count, &taps, &count) == .success else { return nil }
    return taps.prefix(Int(count)).filter { $0.tappingProcess == getpid() }.count
}

private final class LockedEvents: @unchecked Sendable {
    struct Entry {
        let onTapThread: Bool
        let at: DispatchTime
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(onTapThread: Bool, at: DispatchTime) {
        lock.withLock { entries.append(Entry(onTapThread: onTapThread, at: at)) }
    }

    var first: Entry? { lock.withLock { entries.first } }
}

private final class LockedTime: @unchecked Sendable {
    private let lock = NSLock()
    private var time: DispatchTime?

    func set(_ value: DispatchTime) { lock.withLock { time = value } }
    var value: DispatchTime? { lock.withLock { time } }
}

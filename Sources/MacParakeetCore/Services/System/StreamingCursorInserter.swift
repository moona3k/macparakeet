import AppKit
import Carbon
import CoreGraphics
import Foundation
import OSLog

/// Marks Unicode HID events posted by streaming insertion so hotkey taps ignore them.
public enum StreamingCursorEventMarker {
    public static let userData: Int64 = 0x4D50_5343

    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: userData)
    }

    public static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == userData
    }
}

public enum StreamingCursorError: Error, Equatable {
    case eventSourceUnavailable
    case eventCreationFailed
    case partialInsert
}

public protocol StreamingCursorInserting: Sendable {
    func insert(_ text: String) async throws
}

protocol StreamingCursorEventPosting: Sendable {
    func typeUnicode(_ text: String) throws
}

protocol StreamingCursorClock: Sendable {
    func sleep(for duration: Duration) async throws
}

protocol StreamingCursorInterruptListening: Sendable {
    func start(onInterrupt: @escaping @Sendable () -> Void) -> any StreamingCursorInterruptToken
}

protocol StreamingCursorInterruptToken: Sendable {
    func invalidate()
}

struct ContinuousStreamingClock: StreamingCursorClock {
    func sleep(for duration: Duration) async throws {
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
    }
}

struct CGStreamingCursorEventPosting: StreamingCursorEventPosting {
    func typeUnicode(_ text: String) throws {
        guard AXIsProcessTrusted() else {
            throw StreamingCursorError.eventSourceUnavailable
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw StreamingCursorError.eventSourceUnavailable
        }
        let units = Array(text.utf16)
        guard !units.isEmpty else { return }
        var mutable = units

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw StreamingCursorError.eventCreationFailed
        }

        keyDown.flags = []
        keyUp.flags = []
        StreamingCursorEventMarker.mark(keyDown)
        StreamingCursorEventMarker.mark(keyUp)
        keyDown.keyboardSetUnicodeString(stringLength: mutable.count, unicodeString: &mutable)
        keyUp.keyboardSetUnicodeString(stringLength: mutable.count, unicodeString: &mutable)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

final class HeadInsertStreamingCursorInterrupt: StreamingCursorInterruptListening, @unchecked Sendable {
    func start(onInterrupt: @escaping @Sendable () -> Void) -> any StreamingCursorInterruptToken {
        HeadInsertStreamingCursorInterruptToken(onInterrupt: onInterrupt)
    }
}

private final class HeadInsertStreamingCursorInterruptToken: StreamingCursorInterruptToken, @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<HeadInsertStreamingCursorInterruptToken>?
    private let onInterrupt: @Sendable () -> Void
    private let lock = NSLock()
    private var didInterrupt = false

    init(onInterrupt: @escaping @Sendable () -> Void) {
        self.onInterrupt = onInterrupt
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let token = Unmanaged<HeadInsertStreamingCursorInterruptToken>
                        .fromOpaque(refcon)
                        .takeUnretainedValue()
                    return token.handle(type: type, event: event)
                },
                userInfo: retained.toOpaque()
            )
        else {
            retained.release()
            retainedSelf = nil
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard eventTap != nil || retainedSelf != nil || runLoopSource != nil else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        invalidate()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if StreamingCursorEventMarker.isMarked(event) {
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let first = !didInterrupt
        didInterrupt = true
        lock.unlock()
        if first {
            onInterrupt()
            // Swallow the in-flight session event and re-inject a copy at HID so
            // remainder Unicode posts land before the user's key/click.
            guard let copy = event.copy() else {
                return Unmanaged.passUnretained(event)
            }
            copy.post(tap: .cghidEventTap)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

public final class StreamingCursorInserter: StreamingCursorInserting, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "StreamingCursor")
    private let posting: any StreamingCursorEventPosting
    private let clock: any StreamingCursorClock
    private let interrupts: any StreamingCursorInterruptListening

    public convenience init() {
        self.init(
            posting: CGStreamingCursorEventPosting(),
            clock: ContinuousStreamingClock(),
            interrupts: HeadInsertStreamingCursorInterrupt()
        )
    }

    init(
        posting: any StreamingCursorEventPosting,
        clock: any StreamingCursorClock,
        interrupts: any StreamingCursorInterruptListening
    ) {
        self.posting = posting
        self.clock = clock
        self.interrupts = interrupts
    }

    public func insert(_ text: String) async throws {
        let schedule = StreamingCursorScheduler.schedule(text)
        let playback = StreamingCursorPlayback(
            posting: posting,
            remaining: schedule.batches.map(\.text)
        )

        let token = startInterruptTap(playback: playback)
        defer { invalidateInterruptTap(token) }

        do {
            for batch in schedule.batches {
                try Task.checkCancellation()
                if playback.isInterrupted {
                    break
                }
                if batch.delayBefore > .zero {
                    try await clock.sleep(for: batch.delayBefore)
                }
                try Task.checkCancellation()
                try playback.playIfCurrent(batch.text)
            }
            try playback.drainRemaining(soft: false)
        } catch is CancellationError {
            playback.interruptAndDrain()
            return
        } catch {
            if playback.committedCount == 0 {
                throw error
            }
            do {
                try playback.drainRemaining(soft: false)
            } catch {
                logger.error("streaming_cursor_partial_flush_failed")
                throw StreamingCursorError.partialInsert
            }
        }

        if playback.committedCount > 0, !schedule.isInstant, !playback.isInterrupted {
            try? await clock.sleep(for: StreamingCursorPolicy.settleDuration)
        }
    }

    private func startInterruptTap(playback: StreamingCursorPlayback) -> any StreamingCursorInterruptToken {
        let start = { [interrupts] in
            interrupts.start {
                playback.interruptAndDrain()
            }
        }
        if Thread.isMainThread {
            return start()
        }
        return DispatchQueue.main.sync(execute: start)
    }

    private func invalidateInterruptTap(_ token: any StreamingCursorInterruptToken) {
        let invalidate = { token.invalidate() }
        if Thread.isMainThread {
            invalidate()
            return
        }
        DispatchQueue.main.sync(execute: invalidate)
    }
}

/// Serializes HID posts so a head-insert interrupt cannot reorder or duplicate chunks.
private final class StreamingCursorPlayback: @unchecked Sendable {
    private let posting: any StreamingCursorEventPosting
    private let lock = NSRecursiveLock()
    private var remaining: [String]
    private var interrupted = false
    private var committed = 0

    init(posting: any StreamingCursorEventPosting, remaining: [String]) {
        self.posting = posting
        self.remaining = remaining
    }

    var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    var committedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    func interruptAndDrain() {
        lock.lock()
        defer { lock.unlock() }
        interrupted = true
        try? drainLocked(soft: true)
    }

    func playIfCurrent(_ expected: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !interrupted, remaining.first == expected else { return }
        remaining.removeFirst()
        do {
            try posting.typeUnicode(expected)
            committed += 1
        } catch {
            remaining.insert(expected, at: 0)
            throw error
        }
    }

    func drainRemaining(soft: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        try drainLocked(soft: soft)
    }

    private func drainLocked(soft: Bool) throws {
        while let chunk = remaining.first {
            remaining.removeFirst()
            guard !chunk.isEmpty else { continue }
            do {
                try posting.typeUnicode(chunk)
                committed += 1
            } catch {
                remaining.insert(chunk, at: 0)
                if soft { return }
                throw error
            }
        }
    }
}

public enum StreamingCursorInputSource {
    public static func allowsStreaming() -> Bool {
        StreamingCursorPolicy.inputSourceAllowsStreaming(asciiCapable: liveASCIICapable())
    }

    static func liveASCIICapable() -> Bool? {
        guard let sourceRef = TISCopyCurrentKeyboardInputSource() else {
            return nil
        }
        let source = sourceRef.takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return nil
        }
        let flag = Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
        return CFBooleanGetValue(flag)
    }
}

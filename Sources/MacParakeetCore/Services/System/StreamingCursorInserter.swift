import AppKit
import Carbon
import CoreGraphics
import Foundation
import OSLog

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
    /// Idempotently stop listening and wait for any in-flight callback to finish.
    func invalidate()
}

struct ContinuousStreamingClock: StreamingCursorClock {
    func sleep(for duration: Duration) async throws {
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
    }
}

struct CGStreamingCursorEventPosting: StreamingCursorEventPosting {
    /// Forward intercepted input at the same stage as the flushed text. The
    /// original event has reached the session stage; replay must not write to HID.
    /// Preserve user/third-party identity rather than marking it as our output.
    static func replayInterceptedInput(
        _ event: CGEvent,
        postEvent: (CGEvent, CGEventTapLocation) -> Void = { $0.post(tap: $1) }
    ) -> Bool {
        guard let copy = event.copy() else { return false }
        postEvent(copy, AppGeneratedKeyboardEvents.postingLocation)
        return true
    }

    func typeUnicode(_ text: String) throws {
        guard AXIsProcessTrusted() else {
            throw StreamingCursorError.eventSourceUnavailable
        }
        guard let source = AppGeneratedKeyboardEvents.makeSource() else {
            throw StreamingCursorError.eventSourceUnavailable
        }
        let units = Array(text.utf16)
        guard !units.isEmpty else { return }
        var mutable = units

        guard let keyDown = AppGeneratedKeyboardEvents.makeEvent(source: source, keyCode: 0, keyDown: true, flags: []),
            let keyUp = AppGeneratedKeyboardEvents.makeEvent(source: source, keyCode: 0, keyDown: false, flags: [])
        else {
            throw StreamingCursorError.eventCreationFailed
        }

        keyDown.keyboardSetUnicodeString(stringLength: mutable.count, unicodeString: &mutable)
        keyUp.keyboardSetUnicodeString(stringLength: mutable.count, unicodeString: &mutable)
        keyDown.post(tap: AppGeneratedKeyboardEvents.postingLocation)
        keyUp.post(tap: AppGeneratedKeyboardEvents.postingLocation)
    }
}

final class HeadInsertStreamingCursorInterrupt: StreamingCursorInterruptListening, @unchecked Sendable {
    func start(onInterrupt: @escaping @Sendable () -> Void) -> any StreamingCursorInterruptToken {
        HeadInsertStreamingCursorInterruptToken(onInterrupt: onInterrupt)
    }
}

private final class HeadInsertStreamingCursorInterruptToken: StreamingCursorInterruptToken, @unchecked Sendable {
    private let onInterrupt: @Sendable () -> Void
    private let lock = NSLock()
    private var eventTap: BackgroundEventTap?
    private var didInterrupt = false

    init(onInterrupt: @escaping @Sendable () -> Void) {
        self.onInterrupt = onInterrupt
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        // Runs on `EventTapThread`, so a stalled main thread cannot hold the
        // user's keys and clicks while text streams (#1142).
        let tap = BackgroundEventTap.start(
            options: .defaultTap,
            eventsOfInterest: mask,
            handler: { [weak self] type, event in
                guard let self else { return Unmanaged.passUnretained(event) }
                return self.handle(type: type, event: event)
            }
        )
        lock.withLock { eventTap = tap }
    }

    func invalidate() {
        let tap = lock.withLock {
            let tap = eventTap
            eventTap = nil
            return tap
        }
        tap?.stop()
    }

    deinit {
        invalidate()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // `BackgroundEventTap` already re-enabled the tap.
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
            // Queue input behind any text the flush posted, even if it failed.
            // Use the session entry point; replaying upstream contaminates HID.
            guard CGStreamingCursorEventPosting.replayInterceptedInput(event) else {
                return Unmanaged.passUnretained(event)
            }
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
            if playback.stopIfUncommitted() {
                // Do not hold playback's lock while waiting for the tap. An
                // in-flight callback may still record the user's interruption.
                invalidateInterruptTap(token)
                throw playback.isInterrupted ? StreamingCursorError.partialInsert : error
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
        // The tap lives on `EventTapThread`; no main-thread hop is needed.
        interrupts.start {
            playback.interruptAndDrain()
        }
    }

    private func invalidateInterruptTap(_ token: any StreamingCursorInterruptToken) {
        token.invalidate()
    }
}

/// Serializes text posts so a head-insert interrupt cannot reorder or duplicate chunks.
private final class StreamingCursorPlayback: @unchecked Sendable {
    private let posting: any StreamingCursorEventPosting
    private let lock = NSRecursiveLock()
    private var remaining: [String]
    private var interrupted = false
    private var postingStopped = false
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

    /// Stop pending posts before error handling waits for the interrupt tap.
    func stopIfUncommitted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard committed == 0 else { return false }
        postingStopped = true
        return true
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
        guard !interrupted, !postingStopped, remaining.first == expected else { return }
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
        // The user's key/click resumes after the interrupt callback. Once its
        // flush fails, retrying here could type into a different cursor or app.
        // partialInsert also prevents the caller's automatic full-paste fallback.
        guard !postingStopped else { throw StreamingCursorError.partialInsert }
        while let chunk = remaining.first {
            remaining.removeFirst()
            guard !chunk.isEmpty else { continue }
            do {
                try posting.typeUnicode(chunk)
                committed += 1
            } catch {
                remaining.insert(chunk, at: 0)
                if soft {
                    postingStopped = true
                    return
                }
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

import Foundation

/// A synchronous fence for speech events already queued for UI delivery. Physical
/// Stop cannot wait for an actor hop: that hop may sit behind captured samples.
final class VoiceControlSpeechRevocation: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?
    private var paused = false

    func beginCapture(utterance: UUID) {
        lock.lock(); defer { lock.unlock() }
        current = utterance
        paused = false
    }
    @discardableResult func beginUtterance(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !paused else { return false }
        current = id
        return true
    }
    func revoke() {
        lock.lock(); defer { lock.unlock() }
        current = nil
        paused = true
    }
    var needsSilenceRearm: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }
    func rearmAfterSilence() {
        lock.lock(); defer { lock.unlock() }
        paused = false
        current = nil
    }
    func accepts(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !paused && current == id
    }
}

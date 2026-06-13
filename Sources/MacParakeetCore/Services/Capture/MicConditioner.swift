import Foundation

struct MeetingEchoSuppressionDiagnostics: Sendable, Equatable {
    var processorName: String
    var loaded: Bool
    var micFrames: Int
    var processedFrames: Int
    var rawFallbackFrames: Int
    var fullReferenceFrames: Int
    var partialReferenceFrames: Int
    var missingReferenceFrames: Int
    var processingFailures: Int

    static func passthrough(
        processorName: String = "passthrough",
        loaded: Bool = true
    ) -> MeetingEchoSuppressionDiagnostics {
        MeetingEchoSuppressionDiagnostics(
            processorName: processorName,
            loaded: loaded,
            micFrames: 0,
            processedFrames: 0,
            rawFallbackFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            processingFailures: 0
        )
    }
}

protocol MeetingEchoSuppressing: AnyObject, Sendable {
    var name: String { get }
    var sampleRate: Int { get }
    var frameSize: Int { get }
    func reset()
    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws
}

protocol MicConditioning: AnyObject, Sendable {
    var diagnostics: MeetingEchoSuppressionDiagnostics { get }
    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float]
    /// Drain any microphone samples held back by internal framing, raw.
    /// Stateless conditioners hold nothing and return `[]` (the default).
    func flush() -> [Float]
    func reset()
}

extension MicConditioning {
    func condition(microphone: [Float], speaker: [Float]) -> [Float] {
        condition(microphone: microphone, speaker: speaker, hasSpeakerReference: !speaker.isEmpty)
    }

    func flush() -> [Float] {
        []
    }
}

/// No-op pass-through. This is the call-safe baseline: MacParakeet keeps raw
/// mic capture and only enables model-backed cleanup when a local processor is
/// explicitly configured and loaded.
final class PassthroughMicConditioner: MicConditioning, @unchecked Sendable {
    private let processorName: String
    private let loaded: Bool
    private let lock = NSLock()
    private var diagnosticsStorage: MeetingEchoSuppressionDiagnostics

    var diagnostics: MeetingEchoSuppressionDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsStorage
    }

    init(processorName: String = "passthrough", loaded: Bool = true) {
        self.processorName = processorName
        self.loaded = loaded
        self.diagnosticsStorage = MeetingEchoSuppressionDiagnostics.passthrough(
            processorName: processorName,
            loaded: loaded
        )
    }

    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        microphone
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        diagnosticsStorage = MeetingEchoSuppressionDiagnostics.passthrough(
            processorName: processorName,
            loaded: loaded
        )
    }
}

/// Streams microphone batches through a frame-based echo processor.
///
/// Incoming batches rarely align with the processor's hop size, so samples
/// that do not yet fill a frame are carried across `condition` calls instead
/// of leaking through raw — the processor's streaming state requires
/// contiguous frames. Reference (speaker) samples are appended in lockstep
/// with microphone samples and retained `referenceDelaySamples` longer, so a
/// frame at stream position `p` is cancelled against reference audio from
/// `p - referenceDelaySamples` (the echo path is causal: speaker audio leaks
/// into the mic only after output + acoustic + input latency).
final class StreamingMeetingEchoSuppressor: MicConditioning, @unchecked Sendable {
    private let processor: any MeetingEchoSuppressing
    private let referenceDelaySamples: Int
    private let lock = NSLock()
    private var diagnosticsStorage: MeetingEchoSuppressionDiagnostics

    // `pendingMicrophone[0]` sits at absolute stream position
    // `microphonePosition`; `referenceHistory[0]` at `referencePosition`.
    // Invariant: referencePosition + referenceHistory.count ==
    // microphonePosition + pendingMicrophone.count.
    private var pendingMicrophone: [Float] = []
    private var referenceHistory: [Float] = []
    private var referenceValidity: [Bool] = []
    private var microphonePosition = 0
    private var referencePosition = 0

    var diagnostics: MeetingEchoSuppressionDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsStorage
    }

    init(processor: any MeetingEchoSuppressing, referenceDelaySamples: Int = 0) {
        self.processor = processor
        self.referenceDelaySamples = max(0, referenceDelaySamples)
        self.diagnosticsStorage = MeetingEchoSuppressionDiagnostics(
            processorName: processor.name,
            loaded: true,
            micFrames: 0,
            processedFrames: 0,
            rawFallbackFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            processingFailures: 0
        )
    }

    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        guard !microphone.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        pendingMicrophone.append(contentsOf: microphone)
        for index in 0..<microphone.count {
            let hasSample = hasSpeakerReference && index < speaker.count
            referenceHistory.append(hasSample ? speaker[index] : 0)
            referenceValidity.append(hasSample)
        }

        return drainProcessableFramesLocked()
    }

    func flush() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        guard !pendingMicrophone.isEmpty else { return [] }
        let tail = pendingMicrophone
        diagnosticsStorage.rawFallbackFrames += 1
        advanceConsumedLocked(by: tail.count)
        return tail
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        processor.reset()
        pendingMicrophone.removeAll()
        referenceHistory.removeAll()
        referenceValidity.removeAll()
        microphonePosition = 0
        referencePosition = 0
        diagnosticsStorage = MeetingEchoSuppressionDiagnostics(
            processorName: processor.name,
            loaded: true,
            micFrames: 0,
            processedFrames: 0,
            rawFallbackFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            processingFailures: 0
        )
    }

    private enum ReferenceQuality {
        case full
        case partial
        case missing
    }

    private func drainProcessableFramesLocked() -> [Float] {
        let frameSize = max(processor.frameSize, 1)
        guard pendingMicrophone.count >= frameSize else { return [] }

        var output: [Float] = []
        output.reserveCapacity(pendingMicrophone.count)
        var micFrame = [Float](repeating: 0, count: frameSize)
        var referenceFrame = [Float](repeating: 0, count: frameSize)
        var processedFrame = [Float](repeating: 0, count: frameSize)
        var consumed = 0

        while consumed + frameSize <= pendingMicrophone.count {
            for offset in 0..<frameSize {
                micFrame[offset] = pendingMicrophone[consumed + offset]
            }
            let referenceQuality = fillReferenceFrameLocked(
                &referenceFrame,
                frameStartPosition: microphonePosition + consumed
            )

            diagnosticsStorage.micFrames += 1
            switch referenceQuality {
            case .full:
                diagnosticsStorage.fullReferenceFrames += 1
            case .partial:
                diagnosticsStorage.partialReferenceFrames += 1
            case .missing:
                diagnosticsStorage.missingReferenceFrames += 1
            }

            do {
                try processor.processFrame(
                    microphone: micFrame,
                    reference: referenceFrame,
                    output: &processedFrame
                )
                if processedFrame.count == frameSize {
                    output.append(contentsOf: processedFrame)
                    diagnosticsStorage.processedFrames += 1
                } else {
                    output.append(contentsOf: micFrame)
                    diagnosticsStorage.rawFallbackFrames += 1
                    diagnosticsStorage.processingFailures += 1
                }
            } catch {
                output.append(contentsOf: micFrame)
                diagnosticsStorage.rawFallbackFrames += 1
                diagnosticsStorage.processingFailures += 1
            }

            consumed += frameSize
        }

        advanceConsumedLocked(by: consumed)
        return output
    }

    private func fillReferenceFrameLocked(
        _ frame: inout [Float],
        frameStartPosition: Int
    ) -> ReferenceQuality {
        var validCount = 0
        for offset in frame.indices {
            let absolute = frameStartPosition + offset - referenceDelaySamples
            let index = absolute - referencePosition
            if index >= 0, index < referenceHistory.count, referenceValidity[index] {
                frame[offset] = referenceHistory[index]
                validCount += 1
            } else {
                frame[offset] = 0
            }
        }

        if validCount == frame.count { return .full }
        return validCount == 0 ? .missing : .partial
    }

    private func advanceConsumedLocked(by consumed: Int) {
        guard consumed > 0 else { return }
        pendingMicrophone.removeFirst(consumed)
        microphonePosition += consumed

        let keepFrom = microphonePosition - referenceDelaySamples
        let dropCount = min(max(0, keepFrom - referencePosition), referenceHistory.count)
        if dropCount > 0 {
            referenceHistory.removeFirst(dropCount)
            referenceValidity.removeFirst(dropCount)
            referencePosition += dropCount
        }
    }
}

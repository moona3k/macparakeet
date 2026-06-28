import Foundation
import OSLog

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
    /// Reference delay (samples) currently used to align the system reference to
    /// the microphone. Seeded from configuration, then updated by the adaptive
    /// estimator when one is active.
    var currentDelaySamples: Int = 0
    /// Normalized-correlation confidence of the most recently adopted delay
    /// estimate, in `0...1`. 0 when no estimate has been adopted.
    var delayConfidence: Float = 0
    /// Number of confident delay estimates adopted.
    var delayEstimateCount: Int = 0
    /// Number of delay estimation attempts rejected (silent reference or
    /// below-threshold correlation), kept distinct from adopted estimates so a
    /// silent far-end reads as "nothing to align" rather than a failure.
    var rejectedDelayEstimates: Int = 0

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
/// with microphone samples and retained `currentDelaySamples` longer, so a
/// frame at stream position `p` is cancelled against reference audio from
/// `p - currentDelaySamples` (the echo path is causal: speaker audio leaks
/// into the mic only after output + acoustic + input latency).
///
/// The reference delay is seeded from configuration but, when an estimator is
/// supplied, is re-estimated from the audio itself on a cadence. The
/// measurement harness showed alignment is the dominant factor in cancellation
/// and that the bulk mic/reference offset can exceed any practical filter span,
/// so a static seed alone is too fragile; the estimator recovers the bulk delay
/// while the static value remains a manual seed/override and the value used
/// until the first confident estimate.
final class StreamingMeetingEchoSuppressor: MicConditioning, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingEchoSuppressor")

    private let processor: any MeetingEchoSuppressing
    private let seedDelaySamples: Int
    private let estimator: MeetingEchoDelayEstimator?
    private let reestimateIntervalSamples: Int
    /// Reference history is retained this far behind the microphone so any delay
    /// the estimator may select (up to its max lag) can still be read.
    private let retentionDelaySamples: Int
    /// Most-recent paired samples kept for delay estimation, capped at this many.
    private let analysisCapacity: Int
    /// Minimum paired samples before the first estimate is attempted.
    private let minimumAnalysisSamples: Int
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

    // Effective alignment and adaptive-estimation state.
    private var currentDelaySamples: Int
    private var analysisMicrophone: [Float] = []
    private var analysisReference: [Float] = []
    private var samplesSinceEstimate = 0
    private var hasAttemptedEstimate = false
    /// Bumped by `reset()` so an estimate computed off the lock from pre-reset
    /// audio is discarded instead of overwriting fresh state.
    private var estimationGeneration = 0
    /// Bumped for every scheduled estimate so a slower older snapshot cannot
    /// overwrite a newer result when callers invoke `condition()` concurrently.
    private var latestEstimationAttemptID = 0

    var diagnostics: MeetingEchoSuppressionDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsStorage
    }

    /// - Parameters:
    ///   - referenceDelaySamples: the seed/override alignment; used until the
    ///     first confident estimate, and as the value when `estimator` is nil.
    ///   - estimator: when supplied, the suppressor re-estimates the reference
    ///     delay from paired audio on a cadence. Pass nil to pin the seed.
    ///   - reestimateIntervalSamples: minimum samples between estimation attempts
    ///     after the first.
    init(
        processor: any MeetingEchoSuppressing,
        referenceDelaySamples: Int = 0,
        estimator: MeetingEchoDelayEstimator? = nil,
        reestimateIntervalSamples: Int = 8_000
    ) {
        self.processor = processor
        self.seedDelaySamples = max(0, referenceDelaySamples)
        self.estimator = estimator
        self.reestimateIntervalSamples = max(1, reestimateIntervalSamples)
        self.currentDelaySamples = max(0, referenceDelaySamples)

        if let estimator {
            // estimate() requires count > maxLag + 1, so both the rolling buffer
            // and the trigger threshold must clear maxLag + 2 even for tiny
            // analysis windows; otherwise estimation could never fire.
            let estimateFloor = estimator.maxLagSamples + 2
            self.retentionDelaySamples = max(self.seedDelaySamples, estimator.maxLagSamples)
            self.analysisCapacity = max(
                estimateFloor,
                estimator.maxLagSamples + estimator.analysisWindowSamples)
            self.minimumAnalysisSamples = max(
                estimateFloor,
                estimator.maxLagSamples + min(estimator.analysisWindowSamples, 4_096))
        } else {
            self.retentionDelaySamples = self.seedDelaySamples
            self.analysisCapacity = 0
            self.minimumAnalysisSamples = .max
        }

        self.diagnosticsStorage = Self.freshDiagnostics(
            processorName: processor.name,
            currentDelaySamples: self.currentDelaySamples
        )
    }

    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        guard !microphone.isEmpty else { return [] }

        lock.lock()
        pendingMicrophone.append(contentsOf: microphone)
        for index in 0..<microphone.count {
            let hasSample = hasSpeakerReference && index < speaker.count
            referenceHistory.append(hasSample ? speaker[index] : 0)
            referenceValidity.append(hasSample)
        }
        accumulateAnalysisLocked(microphone: microphone, speaker: speaker, hasSpeakerReference: hasSpeakerReference)
        let output = drainProcessableFramesLocked()
        let pendingEstimate = dueEstimationSnapshotLocked(addedSamples: microphone.count)
        lock.unlock()

        // The cross-correlation is O(maxLag x window); run it off the lock so it
        // never stalls a concurrent condition()/flush()/diagnostics access. The
        // worst case is the estimate landing one batch later than the data that
        // triggered it, which is immaterial at a multi-hundred-ms cadence.
        if let pendingEstimate, let estimator {
            applyDelayEstimate(
                estimator.estimate(
                    microphone: pendingEstimate.microphone,
                    reference: pendingEstimate.reference
                ),
                generation: pendingEstimate.generation,
                attemptID: pendingEstimate.attemptID
            )
        }
        return output
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
        currentDelaySamples = seedDelaySamples
        analysisMicrophone.removeAll()
        analysisReference.removeAll()
        samplesSinceEstimate = 0
        hasAttemptedEstimate = false
        estimationGeneration += 1
        latestEstimationAttemptID += 1
        diagnosticsStorage = Self.freshDiagnostics(
            processorName: processor.name,
            currentDelaySamples: currentDelaySamples
        )
    }

    private static func freshDiagnostics(
        processorName: String,
        currentDelaySamples: Int
    ) -> MeetingEchoSuppressionDiagnostics {
        MeetingEchoSuppressionDiagnostics(
            processorName: processorName,
            loaded: true,
            micFrames: 0,
            processedFrames: 0,
            rawFallbackFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            processingFailures: 0,
            currentDelaySamples: currentDelaySamples
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
            // A processor receives `output` as inout and may resize it; restore
            // the frame size each iteration so one bad frame cannot cascade the
            // rest of this batch to raw fallback.
            if processedFrame.count != frameSize {
                processedFrame = [Float](repeating: 0, count: frameSize)
            }
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
            let absolute = frameStartPosition + offset - currentDelaySamples
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

        let keepFrom = microphonePosition - retentionDelaySamples
        let dropCount = min(max(0, keepFrom - referencePosition), referenceHistory.count)
        if dropCount > 0 {
            referenceHistory.removeFirst(dropCount)
            referenceValidity.removeFirst(dropCount)
            referencePosition += dropCount
        }
    }

    // MARK: Adaptive delay estimation

    /// Append the most-recent paired samples (mic and zero-delay reference) to the
    /// rolling analysis buffers, capped at `analysisCapacity`. These are kept
    /// separate from the processing buffers because the processing path consumes
    /// (and trims) microphone samples as it emits frames, while estimation needs a
    /// contiguous mic/reference window at a shared timebase.
    private func accumulateAnalysisLocked(
        microphone: [Float],
        speaker: [Float],
        hasSpeakerReference: Bool
    ) {
        guard estimator != nil else { return }
        analysisMicrophone.append(contentsOf: microphone)
        if hasSpeakerReference {
            let commonCount = min(microphone.count, speaker.count)
            analysisReference.append(contentsOf: speaker.prefix(commonCount))
            if commonCount < microphone.count {
                analysisReference.append(contentsOf: repeatElement(Float.zero, count: microphone.count - commonCount))
            }
        } else {
            analysisReference.append(contentsOf: repeatElement(Float.zero, count: microphone.count))
        }
        let overflow = analysisMicrophone.count - analysisCapacity
        if overflow > 0 {
            analysisMicrophone.removeFirst(overflow)
            analysisReference.removeFirst(overflow)
        }
    }

    private struct EstimationInput {
        let microphone: [Float]
        let reference: [Float]
        let generation: Int
        let attemptID: Int
    }

    /// If an estimate is due and enough history exists, mark the attempt and
    /// return a copy-on-write snapshot of the analysis buffers to estimate on
    /// outside the lock. Returns nil when no estimator is configured, the buffer
    /// is too small, or the cadence has not elapsed.
    private func dueEstimationSnapshotLocked(addedSamples: Int) -> EstimationInput? {
        guard estimator != nil else { return nil }
        samplesSinceEstimate += addedSamples
        let ready = analysisMicrophone.count >= minimumAnalysisSamples
        let due = !hasAttemptedEstimate || samplesSinceEstimate >= reestimateIntervalSamples
        guard ready, due else { return nil }

        hasAttemptedEstimate = true
        samplesSinceEstimate = 0
        latestEstimationAttemptID += 1
        return EstimationInput(
            microphone: analysisMicrophone,
            reference: analysisReference,
            generation: estimationGeneration,
            attemptID: latestEstimationAttemptID
        )
    }

    private func applyDelayEstimate(
        _ estimate: MeetingEchoDelayEstimate?,
        generation: Int,
        attemptID: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        // Drop a result computed from stale audio: either a reset() has cleared
        // the buffers, or a newer concurrent condition() call has scheduled a
        // fresher snapshot.
        guard generation == estimationGeneration,
            attemptID == latestEstimationAttemptID
        else { return }

        if let estimate {
            let previousDelaySamples = currentDelaySamples
            let previousEstimateCount = diagnosticsStorage.delayEstimateCount
            let adoptedDelaySamples = min(estimate.delaySamples, retentionDelaySamples)
            currentDelaySamples = adoptedDelaySamples
            diagnosticsStorage.currentDelaySamples = currentDelaySamples
            diagnosticsStorage.delayConfidence = estimate.confidence
            diagnosticsStorage.delayEstimateCount += 1
            let adoptedEstimateCount = diagnosticsStorage.delayEstimateCount
            if previousEstimateCount == 0 || previousDelaySamples != adoptedDelaySamples {
                Self.logger.info(
                    "meeting_echo_delay_adopted delay_samples=\(adoptedDelaySamples, privacy: .public) confidence=\(estimate.confidence, privacy: .public) estimate_count=\(adoptedEstimateCount, privacy: .public)"
                )
            }
        } else {
            diagnosticsStorage.rejectedDelayEstimates += 1
        }
    }
}

import AVFoundation
import Foundation
import os
import OSLog

/// Post-stop renderer that derives a cleaned microphone artifact
/// (`microphone-cleaned.m4a`) from the finalized raw `microphone-raw.m4a` +
/// `system-raw.m4a` source files (plan #605 unit U3).
///
/// The raw source files are preserved untouched; the cleaned file is a derived
/// artifact. Rendering reads both raw sources back as 16 kHz mono PCM, aligns
/// the system reference to the microphone using the recorded
/// `MeetingSourceAlignment` start offsets, streams the pair through the same
/// `MicConditioning` seam the live path uses (so the bundled echo suppressor and
/// its adaptive delay estimator do the cancellation), and encodes the result.
///
/// Non-cancellation failures never throw into the recording-finalize path: they
/// resolve to a `.skipped(reason)` outcome and leave the raw sources intact, so
/// a meeting completes even when cleaning is unavailable or fails.
final class MeetingCleanedMicRenderer {
    static let cleanedMicrophoneFileName = MeetingArtifactAudioFileNames.cleanedMicrophone

    /// Sample rate the echo suppressor expects; the cleaned artifact is a derived
    /// STT input (not the playback/export `meeting-playback.m4a`), so 16 kHz mono is fine.
    static let renderSampleRate = 16_000
    static let maxDecodedFrames = renderSampleRate * 4 * 3_600
    /// Production probes use five 10-second windows, spread across the recording
    /// and selected only when the aligned system reference has energy. Within
    /// each window the existing estimator keeps its 8192-sample analysis span,
    /// which measured the same echo/no-echo split without making the probe a
    /// second full render. The threshold is intentionally low: false renders
    /// only cost compute, while a false skip reintroduces speaker bleed.
    static let echoProbeWindowCount = 5
    static let echoProbeWindowSeconds = 10
    static let echoProbeAnalysisSamples = 8_192
    static let echoProbeReferenceRMSFloor: Float = 0.005
    static let echoProbeCorrelationThreshold: Float = 0.08
    /// The recorded host-time offsets can place the system reference a few ms
    /// after its echo in the mic (−1 to −9 ms measured on a speakerphone meeting,
    /// #920). The delay estimator and LocalVQE only model a causal echo path, so
    /// a late reference collapses cancellation to ~1 dB. Offline we have the
    /// whole reference: read it this much earlier so the residual lag is
    /// positive and the estimator recovers it (~22 dB on the same meeting).
    static let referenceLookaheadMs = 20

    private static let logger = Logger(
        subsystem: "com.macparakeet.core", category: "MeetingCleanedMicRenderer")

    struct Result: Sendable, Equatable {
        let outputURL: URL
        let durationSeconds: Double
        /// Frames the processor cleaned vs. served raw (a processor that throws
        /// falls back to raw). Emitted as diagnostics for U9 QA and telemetry,
        /// not a routing gate — U4 prefers the cleaned mic purely on its
        /// valid artifact (see `outputToRawRmsRatio`).
        let processedFrames: Int
        let rawFallbackFrames: Int
        let processingFailures: Int
        let modelVersion: String?
        let renderDurationMs: Int
        let renderRealtimeFactor: Double?
        let delayEstimateMs: Int?
        let echoProbe: EchoPathProbeResult
        /// Output RMS / raw-mic RMS over the render. ~1.0 keeps the local voice;
        /// near 0 means the cleaner gutted the mic. Diagnostic only — it cannot
        /// gate routing: a near-0 ratio is ambiguous between a correctly silenced
        /// mic (near-end stayed quiet) and a gutted one, and falling back to raw
        /// on a low ratio would reintroduce the #605 bleed for listen-heavy
        /// meetings. Near-end fidelity is owned by model choice (v1.4) + U9 QA.
        let outputToRawRmsRatio: Float
    }

    enum SkipReason: Sendable, Equatable {
        /// The conditioner is passthrough or failed to load — cleaning would just
        /// re-encode the raw mic, so there is nothing to derive.
        case conditionerUnavailable
        case missingMicrophoneSource
        case missingSystemReference
        case emptyMicrophone
        case inputTooLong(frameCount: Int, maxFrames: Int)
        case decodeFailed(String)
        case noEchoPath(EchoPathProbeResult)
        case renderFailed(String)
    }

    enum Outcome: Sendable, Equatable {
        case rendered(Result)
        case skipped(SkipReason)
    }

    struct EchoPathProbeResult: Sendable, Equatable {
        let shouldRender: Bool
        let windowsEvaluated: Int
        let bestCorrelation: Float?
        let bestDelaySamples: Int?
        let detail: String
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Render the cleaned mic. `conditioner` is the live factory's product; the
    /// caller passes a freshly built one. Do the heavy decode/encode off the
    /// main actor. Normal render failures return `.skipped`; cooperative
    /// cancellation is rethrown so detached callers can be interrupted.
    func render(
        microphoneURL: URL,
        systemURL: URL,
        sourceAlignment: MeetingSourceAlignment,
        outputURL: URL,
        conditioner: any MicConditioning
    ) async throws -> Outcome {
        try await render(
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            sourceAlignment: sourceAlignment,
            outputURL: outputURL,
            conditionerFactory: { conditioner }
        )
    }

    /// Render the cleaned mic after first probing whether a system-reference
    /// echo path exists. The conditioner factory is deliberately invoked only
    /// after the probe says to render, so no-echo meetings avoid LocalVQE load.
    func render(
        microphoneURL: URL,
        systemURL: URL,
        sourceAlignment: MeetingSourceAlignment,
        outputURL: URL,
        conditionerFactory: @escaping @Sendable () -> any MicConditioning
    ) async throws -> Outcome {
        let renderStartedAt = Date()
        guard fileManager.fileExists(atPath: microphoneURL.path) else {
            return .skipped(.missingMicrophoneSource)
        }
        guard fileManager.fileExists(atPath: systemURL.path) else {
            return .skipped(.missingSystemReference)
        }

        let microphone: MeetingAudioSamples
        let system: MeetingAudioSamples
        do {
            try Task.checkCancellation()
            microphone = MeetingAudioSamples(
                try await Self.decodeToScratch(
                    url: microphoneURL,
                    sampleRate: Self.renderSampleRate,
                    maxFrames: Self.maxDecodedFrames))
            try Task.checkCancellation()
            system = MeetingAudioSamples(
                try await Self.decodeToScratch(
                    url: systemURL,
                    sampleRate: Self.renderSampleRate,
                    maxFrames: Self.maxDecodedFrames))
        } catch is CancellationError {
            throw CancellationError()
        } catch DecodeLimitExceeded.tooManyFrames(let frameCount, let maxFrames) {
            return .skipped(.inputTooLong(frameCount: frameCount, maxFrames: maxFrames))
        } catch {
            return .skipped(.decodeFailed(String(describing: error)))
        }
        guard microphone.count > 0 else { return .skipped(.emptyMicrophone) }
        guard max(microphone.count, system.count) <= Self.maxDecodedFrames else {
            return .skipped(
                .inputTooLong(
                    frameCount: max(microphone.count, system.count),
                    maxFrames: Self.maxDecodedFrames))
        }
        try Task.checkCancellation()

        let echoProbe: EchoPathProbeResult
        do {
            echoProbe = try Self.probeEchoPath(
                microphone: microphone,
                system: system,
                microphoneStartOffsetMs: sourceAlignment.microphone?.startOffsetMs ?? 0,
                systemStartOffsetMs: sourceAlignment.system?.startOffsetMs ?? 0,
                sampleRate: Self.renderSampleRate
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .skipped(.decodeFailed(String(describing: error)))
        }
        guard echoProbe.shouldRender else {
            return .skipped(.noEchoPath(echoProbe))
        }

        // Only derive when a real echo processor loaded. Passthrough (no assets)
        // and unavailable (load failed) both leave the raw mic as the truth.
        let conditioner = conditionerFactory()
        let diagnostics = conditioner.diagnostics
        guard diagnostics.loaded,
            !(conditioner is PassthroughMicConditioner)
        else {
            return .skipped(.conditionerUnavailable)
        }

        let conditioned = ConditionedStream(
            microphone: microphone,
            system: system,
            microphoneStartOffsetMs: sourceAlignment.microphone?.startOffsetMs ?? 0,
            systemStartOffsetMs: sourceAlignment.system?.startOffsetMs ?? 0,
            sampleRate: Self.renderSampleRate,
            conditioner: conditioner
        )
        do {
            try await Self.encodeMonoFloat(
                sampleRate: Self.renderSampleRate, to: outputURL,
                fileManager: fileManager, nextSamples: conditioned.next)
        } catch is CancellationError {
            try? fileManager.removeItem(at: outputURL)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: outputURL)
            return .skipped(.renderFailed(String(describing: error)))
        }

        let duration = Double(conditioned.emittedCount) / Double(Self.renderSampleRate)
        let ratio = conditioned.rmsRatio
        let renderDurationMs = max(
            0,
            Int((Date().timeIntervalSince(renderStartedAt) * 1_000).rounded())
        )
        let renderSeconds = Double(renderDurationMs) / 1_000
        let realtimeFactor = renderSeconds > 0 ? duration / renderSeconds : nil
        let renderDiagnostics = conditioner.diagnostics
        let delayEstimateMs: Int?
        if renderDiagnostics.delayEstimateCount > 0 {
            delayEstimateMs = Int(
                (Double(renderDiagnostics.currentDelaySamples)
                    / Double(Self.renderSampleRate) * 1_000).rounded())
        } else {
            delayEstimateMs = nil
        }
        Self.logger.info(
            "meeting_cleaned_mic_rendered duration_s=\(duration, format: .fixed(precision: 1), privacy: .public) render_duration_ms=\(renderDurationMs, privacy: .public) processed_frames=\(renderDiagnostics.processedFrames, privacy: .public) raw_fallback_frames=\(renderDiagnostics.rawFallbackFrames, privacy: .public) failures=\(renderDiagnostics.processingFailures, privacy: .public) rms_ratio=\(ratio, format: .fixed(precision: 2), privacy: .public)"
        )
        return .rendered(
            Result(
                outputURL: outputURL,
                durationSeconds: duration,
                processedFrames: renderDiagnostics.processedFrames,
                rawFallbackFrames: renderDiagnostics.rawFallbackFrames,
                processingFailures: renderDiagnostics.processingFailures,
                modelVersion: renderDiagnostics.modelVersion ?? renderDiagnostics.processorName,
                renderDurationMs: renderDurationMs,
                renderRealtimeFactor: realtimeFactor,
                delayEstimateMs: delayEstimateMs,
                echoProbe: echoProbe,
                outputToRawRmsRatio: ratio))
    }

    static func probeEchoPath(
        microphone: [Float],
        system: [Float],
        microphoneStartOffsetMs: Int,
        systemStartOffsetMs: Int,
        sampleRate: Int
    ) throws -> EchoPathProbeResult {
        try probeEchoPath(
            microphone: MeetingAudioSamples(microphone), system: MeetingAudioSamples(system),
            microphoneStartOffsetMs: microphoneStartOffsetMs,
            systemStartOffsetMs: systemStartOffsetMs, sampleRate: sampleRate)
    }

    static func probeEchoPath(
        microphone: MeetingAudioSamples,
        system: MeetingAudioSamples,
        microphoneStartOffsetMs: Int,
        systemStartOffsetMs: Int,
        sampleRate: Int
    ) throws -> EchoPathProbeResult {
        let sampleRate = max(1, sampleRate)
        let maxLagSamples = max(1, sampleRate / 5)
        let targetWindowSamples = max(1, sampleRate * echoProbeWindowSeconds)
        let windowLength = min(targetWindowSamples, microphone.count)
        guard windowLength > maxLagSamples + 1 else {
            return EchoPathProbeResult(
                shouldRender: system.count > 0,
                windowsEvaluated: 0,
                bestCorrelation: nil,
                bestDelaySamples: nil,
                detail: "inconclusive_short_audio"
            )
        }

        let relativeShiftSamples = referenceShiftSamples(
            microphoneStartOffsetMs: microphoneStartOffsetMs,
            systemStartOffsetMs: systemStartOffsetMs,
            sampleRate: sampleRate)
        let starts = probeCandidateWindowStarts(
            sampleCount: microphone.count,
            windowLength: windowLength,
            candidateCount: echoProbeWindowCount * 4
        )
        let energeticStarts = try starts.compactMap { start -> Int? in
            let rms = try alignedReferenceRMS(
                system: system,
                start: start,
                windowLength: windowLength,
                relativeShiftSamples: relativeShiftSamples
            )
            return rms >= echoProbeReferenceRMSFloor ? start : nil
        }
        guard !energeticStarts.isEmpty else {
            return EchoPathProbeResult(
                shouldRender: false,
                windowsEvaluated: 0,
                bestCorrelation: nil,
                bestDelaySamples: nil,
                detail: "no_reference_energy"
            )
        }

        let selectedStarts = evenlySpacedSelection(
            energeticStarts,
            limit: echoProbeWindowCount
        )
        let analysisLength = min(windowLength, max(maxLagSamples + 2, echoProbeAnalysisSamples))
        let estimator = MeetingEchoDelayEstimator(
            maxLagSamples: maxLagSamples,
            minConfidence: 0,
            analysisWindowSamples: analysisLength
        )
        var bestCorrelation: Float?
        var bestDelaySamples: Int?
        var evaluated = 0
        for start in selectedStarts {
            try Task.checkCancellation()
            let analysisStart = try bestAnalysisStart(
                system: system,
                windowStart: start,
                windowLength: windowLength,
                analysisLength: analysisLength,
                relativeShiftSamples: relativeShiftSamples
            )
            let analysisEnd = analysisStart + analysisLength
            let micWindow = try microphone.read(analysisStart..<analysisEnd)
            let referenceWindow = try alignedReferenceWindow(
                system: system,
                start: analysisStart,
                windowLength: analysisLength,
                relativeShiftSamples: relativeShiftSamples
            )
            evaluated += 1
            guard
                let estimate = estimator.estimate(
                    microphone: micWindow,
                    reference: referenceWindow
                )
            else {
                continue
            }
            if bestCorrelation == nil || estimate.confidence > bestCorrelation! {
                bestCorrelation = estimate.confidence
                bestDelaySamples = estimate.delaySamples
            }
            if estimate.confidence >= echoProbeCorrelationThreshold {
                return EchoPathProbeResult(
                    shouldRender: true,
                    windowsEvaluated: evaluated,
                    bestCorrelation: bestCorrelation,
                    bestDelaySamples: bestDelaySamples,
                    detail: "echo_detected"
                )
            }
        }

        return EchoPathProbeResult(
            shouldRender: false,
            windowsEvaluated: evaluated,
            bestCorrelation: bestCorrelation,
            bestDelaySamples: bestDelaySamples,
            detail: "below_threshold"
        )
    }

    private static func probeCandidateWindowStarts(
        sampleCount: Int,
        windowLength: Int,
        candidateCount: Int
    ) -> [Int] {
        let span = max(0, sampleCount - windowLength)
        guard span > 0 else { return [0] }
        let count = max(1, candidateCount)
        guard count > 1 else { return [0] }
        var starts = Set<Int>()
        for index in 0..<count {
            let position = Double(span) * Double(index) / Double(count - 1)
            starts.insert(Int(position.rounded()))
        }
        return starts.sorted()
    }

    private static func evenlySpacedSelection(_ values: [Int], limit: Int) -> [Int] {
        guard values.count > limit, limit > 1 else { return Array(values.prefix(max(0, limit))) }
        var selected: [Int] = []
        selected.reserveCapacity(limit)
        for index in 0..<limit {
            let position = Double(values.count - 1) * Double(index) / Double(limit - 1)
            selected.append(values[Int(position.rounded())])
        }
        return selected
    }

    private static func bestAnalysisStart(
        system: MeetingAudioSamples,
        windowStart: Int,
        windowLength: Int,
        analysisLength: Int,
        relativeShiftSamples: Int
    ) throws -> Int {
        let span = max(0, windowLength - analysisLength)
        guard span > 0 else { return windowStart }
        let starts = probeCandidateWindowStarts(
            sampleCount: windowLength,
            windowLength: analysisLength,
            candidateCount: 5
        ).map { windowStart + $0 }
        return try starts.max { lhs, rhs in
            try alignedReferenceRMS(
                system: system,
                start: lhs,
                windowLength: analysisLength,
                relativeShiftSamples: relativeShiftSamples
            )
                < alignedReferenceRMS(
                    system: system,
                    start: rhs,
                    windowLength: analysisLength,
                    relativeShiftSamples: relativeShiftSamples
                )
        } ?? windowStart
    }

    private static func alignedReferenceRMS(
        system: MeetingAudioSamples,
        start: Int,
        windowLength: Int,
        relativeShiftSamples: Int
    ) throws -> Float {
        guard windowLength > 0 else { return 0 }
        try Task.checkCancellation()
        let samples = try alignedReferenceWindow(
            system: system, start: start, windowLength: windowLength,
            relativeShiftSamples: relativeShiftSamples)
        var power: Double = 0
        for sample in samples { power += Double(sample) * Double(sample) }
        return Float((power / Double(windowLength)).squareRoot())
    }

    /// Where system sample 0 lands on the mic timeline: the recorded start-offset
    /// difference, minus `referenceLookaheadMs`.
    static func referenceShiftSamples(
        microphoneStartOffsetMs: Int,
        systemStartOffsetMs: Int,
        sampleRate: Int
    ) -> Int {
        let shiftMs = systemStartOffsetMs - microphoneStartOffsetMs - referenceLookaheadMs
        return Int((Double(shiftMs) / 1000.0 * Double(max(1, sampleRate))).rounded())
    }

    private static func alignedReferenceWindow(
        system: MeetingAudioSamples,
        start: Int,
        windowLength: Int,
        relativeShiftSamples: Int
    ) throws -> [Float] {
        let sourceStart = start - relativeShiftSamples
        let lower = max(0, sourceStart)
        let upper = min(system.count, sourceStart + windowLength)
        var window = [Float](repeating: 0, count: windowLength)
        if lower < upper {
            let samples = try system.read(lower..<upper)
            window.replaceSubrange((lower - sourceStart)..<(upper - sourceStart), with: samples)
        }
        return window
    }

    // MARK: DSP core (pure; unit-tested independently of audio codecs)

    struct ConditionedOutput: Sendable, Equatable {
        let output: [Float]
        let processedFrames: Int
        let rawFallbackFrames: Int
        let processingFailures: Int
    }

    /// Align the system reference to the microphone by their recorded start
    /// offsets, then stream the pair through the conditioner. Output is aligned
    /// 1:1 with the microphone samples (the conditioner's `flush()` drains any
    /// held tail), so the cleaned file has the same duration as the raw mic.
    static func alignAndCondition(
        microphone: [Float],
        system: [Float],
        microphoneStartOffsetMs: Int,
        systemStartOffsetMs: Int,
        sampleRate: Int,
        conditioner: any MicConditioning
    ) throws -> ConditionedOutput {
        let stream = ConditionedStream(
            microphone: MeetingAudioSamples(microphone), system: MeetingAudioSamples(system),
            microphoneStartOffsetMs: microphoneStartOffsetMs,
            systemStartOffsetMs: systemStartOffsetMs, sampleRate: sampleRate,
            conditioner: conditioner)
        var output: [Float] = []
        while let chunk = try stream.next() { output.append(contentsOf: chunk) }
        let diagnostics = conditioner.diagnostics
        return ConditionedOutput(
            output: output, processedFrames: diagnostics.processedFrames,
            rawFallbackFrames: diagnostics.rawFallbackFrames,
            processingFailures: diagnostics.processingFailures)
    }

    /// Pull-based output keeps codec backpressure from accumulating cleaned PCM.
    /// The production inputs are scratch files; memory fixtures use this same
    /// alignment, conditioner cadence, flush, trim and raw-tail fallback.
    final class ConditionedStream {
        private let microphone: MeetingAudioSamples
        private let system: MeetingAudioSamples
        private let relativeShiftSamples: Int
        private let conditioner: any MicConditioning
        private var cursor = 0
        private var flushed = false
        private var inputPower = 0.0
        private var outputPower = 0.0
        private(set) var emittedCount = 0
        static let blockFrames = 4_096

        init(
            microphone: MeetingAudioSamples, system: MeetingAudioSamples,
            microphoneStartOffsetMs: Int, systemStartOffsetMs: Int,
            sampleRate: Int, conditioner: any MicConditioning
        ) {
            self.microphone = microphone
            self.system = system
            self.conditioner = conditioner
            relativeShiftSamples = MeetingCleanedMicRenderer.referenceShiftSamples(
                microphoneStartOffsetMs: microphoneStartOffsetMs,
                systemStartOffsetMs: systemStartOffsetMs,
                sampleRate: sampleRate)
            conditioner.reset()
        }

        var rmsRatio: Float {
            guard inputPower > 0, emittedCount > 0 else { return 0 }
            return Float((outputPower / inputPower).squareRoot())
        }

        func next() throws -> [Float]? {
            while true {
                try Task.checkCancellation()
                let chunk: [Float]
                if cursor < microphone.count {
                    let end = min(cursor + Self.blockFrames, microphone.count)
                    let mic = try microphone.read(cursor..<end)
                    for sample in mic { inputPower += Double(sample) * Double(sample) }
                    let reference = try alignedReferenceWindow(
                        system: system, start: cursor, windowLength: end - cursor,
                        relativeShiftSamples: relativeShiftSamples)
                    chunk = conditioner.condition(
                        microphone: mic, speaker: reference, hasSpeakerReference: true)
                    cursor = end
                } else if !flushed {
                    flushed = true
                    chunk = conditioner.flush()
                } else if emittedCount < microphone.count {
                    // An under-flushing conditioner must not shorten the file.
                    chunk = try microphone.read(
                        emittedCount..<min(emittedCount + Self.blockFrames, microphone.count))
                } else {
                    return nil
                }
                // Flush can round up to a complete DSP frame. Keep exactly the
                // microphone's length, just as the previous array render did.
                let output = Array(chunk.prefix(max(0, microphone.count - emittedCount)))
                for sample in output { outputPower += Double(sample) * Double(sample) }
                emittedCount += output.count
                if !output.isEmpty { return output }
            }
        }
    }

    // MARK: Audio I/O

    enum DecodeLimitExceeded: Error, Equatable {
        case tooManyFrames(frameCount: Int, maxFrames: Int)
    }

    static func decodeToScratch(
        url: URL, sampleRate: Int, maxFrames: Int
    ) async throws -> MeetingDecodedAudio {
        let audio = try MeetingDecodedAudio()
        try await decodeMonoFloatChunks(url: url, sampleRate: sampleRate, maxFrames: maxFrames) {
            try audio.append($0)
        }
        return audio
    }

    /// Array collector for small fixtures. Production render uses disk-backed
    /// samples, including the echo probe, and never calls this collector.
    static func decodeMonoFloat(
        url: URL, sampleRate: Int, maxFrames: Int? = nil
    ) async throws -> [Float] {
        var samples: [Float] = []
        try await decodeMonoFloatChunks(url: url, sampleRate: sampleRate, maxFrames: maxFrames) {
            samples.append(contentsOf: $0)
        }
        return samples
    }

    private static func decodeMonoFloatChunks(
        url: URL, sampleRate: Int, maxFrames: Int?,
        consume: (UnsafeBufferPointer<Float>) throws -> Void
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            )
        else {
            throw MeetingAudioError.storageFailed("invalid decode format")
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw MeetingAudioError.storageFailed("decode converter unavailable")
        }

        var decodedCount = 0
        let sourceRate = file.processingFormat.sampleRate
        // Corrupt files can report zero/sub-Hz source rates; fail before ratio
        // math so output-buffer sizing cannot explode into OOM-scale requests.
        guard sourceRate.isFinite, sourceRate >= 1_000 else {
            throw MeetingAudioError.storageFailed("invalid source sample rate")
        }
        let ratio = targetFormat.sampleRate / sourceRate
        let readFrames: AVAudioFrameCount = 16_384
        var reachedEnd = false

        while !reachedEnd {
            try Task.checkCancellation()
            guard
                let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: readFrames
                )
            else {
                throw MeetingAudioError.storageFailed("decode input buffer alloc failed")
            }
            try file.read(into: inputBuffer, frameCount: readFrames)
            let providedFrames = inputBuffer.frameLength
            if providedFrames == 0 { break }

            let capacity = AVAudioFrameCount(Double(providedFrames) * ratio) + 64
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: max(capacity, 1)
                )
            else {
                throw MeetingAudioError.storageFailed("decode output buffer alloc failed")
            }

            var conversionError: NSError?
            let inputWrapper = UncheckedSendableAudioPCMBuffer(inputBuffer)
            let inputConsumed = OSAllocatedUnfairLock(initialState: false)
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                let shouldProvideInput = inputConsumed.withLock { consumed -> Bool in
                    guard !consumed else { return false }
                    consumed = true
                    return true
                }
                if !shouldProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return inputWrapper.buffer
            }
            if status == .error {
                throw MeetingAudioError.storageFailed(
                    conversionError?.localizedDescription ?? "decode conversion failed")
            }
            if status == .endOfStream {
                reachedEnd = true
            }
            if let channel = outputBuffer.floatChannelData?.pointee {
                decodedCount += Int(outputBuffer.frameLength)
                if let maxFrames, decodedCount > maxFrames {
                    throw DecodeLimitExceeded.tooManyFrames(frameCount: decodedCount, maxFrames: maxFrames)
                }
                try consume(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
            }
            await Task.yield()
            if providedFrames < readFrames { reachedEnd = true }
        }

        // Flush any samples the converter is holding (e.g. resampler tail).
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: readFrames
            )
        else {
            throw MeetingAudioError.storageFailed("decode flush buffer alloc failed")
        }
        try Task.checkCancellation()
        var flushError: NSError?
        let status = converter.convert(to: outputBuffer, error: &flushError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if status == .error {
            throw MeetingAudioError.storageFailed(
                flushError?.localizedDescription ?? "decode flush conversion failed")
        }
        if status != .error, let channel = outputBuffer.floatChannelData?.pointee,
            outputBuffer.frameLength > 0
        {
            decodedCount += Int(outputBuffer.frameLength)
            if let maxFrames, decodedCount > maxFrames {
                throw DecodeLimitExceeded.tooManyFrames(frameCount: decodedCount, maxFrames: maxFrames)
            }
            try consume(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
            await Task.yield()
        }
    }

    /// Encode mono Float32 samples to an AAC `.m4a` at `sampleRate`.
    static func encodeMonoFloat(
        _ samples: [Float], sampleRate: Int, to outputURL: URL, fileManager: FileManager
    ) async throws {
        var cursor = 0
        try await encodeMonoFloat(sampleRate: sampleRate, to: outputURL, fileManager: fileManager) {
            guard cursor < samples.count else { return nil }
            let end = min(cursor + 16_384, samples.count)
            defer { cursor = end }
            return Array(samples[cursor..<end])
        }
    }

    private static func encodeMonoFloat(
        sampleRate: Int, to outputURL: URL, fileManager: FileManager,
        nextSamples: () throws -> [Float]?
    ) async throws {
        try? fileManager.removeItem(at: outputURL)
        guard
            let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            )
        else {
            throw MeetingAudioError.storageFailed("invalid encode format")
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        // No explicit bitrate: 64 kbps is above AAC-LC's allowed ceiling for
        // 16 kHz mono and makes the encoder reject the media. Let AVFoundation
        // pick a valid rate for the (sampleRate, channels) pair.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        // Match the proven live storage writer: direct appends gated on
        // `isReadyForMoreMediaData`, no offline `requestMediaDataWhenReady` pump
        // needed for a bounded one-shot render.
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MeetingAudioError.storageFailed("cleaned mic writer cannot add input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MeetingAudioError.storageFailed(
                writer.error?.localizedDescription ?? "cleaned mic writer start failed")
        }
        defer {
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }
        writer.startSession(atSourceTime: .zero)

        let sampleBufferFactory = PCMBufferToSampleBuffer()
        var written: Int64 = 0
        while let samples = try nextSamples() {
            try Task.checkCancellation()
            let frameCount = AVAudioFrameCount(samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount),
                let channel = buffer.floatChannelData?.pointee
            else {
                throw MeetingAudioError.storageFailed("cleaned mic buffer alloc failed")
            }
            buffer.frameLength = frameCount
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: Int(frameCount))
            }
            let sampleBuffer = try sampleBufferFactory.makeSampleBuffer(
                from: buffer, presentationTimeSamples: written)
            while !input.isReadyForMoreMediaData {
                // A failed writer (disk full, sandbox I/O error) can leave
                // `isReadyForMoreMediaData` false forever; bail instead of
                // spinning so finalize/recovery never hang on a broken render.
                // Mirrors the live storage writer, which also gates on
                // `writer.status == .writing`.
                guard writer.status == .writing else {
                    throw MeetingAudioError.storageFailed(
                        writer.error?.localizedDescription ?? "cleaned mic writer failed while waiting")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.append(sampleBuffer) else {
                throw MeetingAudioError.storageFailed(
                    writer.error?.localizedDescription ?? "cleaned mic append failed")
            }
            written += Int64(frameCount)
        }

        try Task.checkCancellation()
        input.markAsFinished()
        await finishWriting(writer)
        if writer.status != .completed {
            throw MeetingAudioError.storageFailed(
                writer.error?.localizedDescription ?? "cleaned mic finalize failed")
        }
    }

    private static func finishWriting(_ writer: AVAssetWriter) async {
        let box = UncheckedSendableBox(writer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.value.finishWriting {
                continuation.resume()
            }
        }
    }
}

/// Minimal Sendable box so the non-Sendable `AVAssetWriter` can be referenced
/// from `finishWriting`'s `@Sendable` completion without capturing `self`.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

import AVFoundation
import Foundation
import OSLog

/// Post-stop renderer that derives a cleaned microphone artifact
/// (`microphone-cleaned.m4a`) from the finalized raw `microphone.m4a` +
/// `system.m4a` source files (plan #605 unit U3).
///
/// The raw source files are preserved untouched; the cleaned file is a derived
/// artifact. Rendering reads both raw sources back as 16 kHz mono PCM, aligns
/// the system reference to the microphone using the recorded
/// `MeetingSourceAlignment` start offsets, streams the pair through the same
/// `MicConditioning` seam the live path uses (so the bundled echo suppressor and
/// its adaptive delay estimator do the cancellation), and encodes the result.
///
/// It never throws into the recording-finalize path: every failure resolves to a
/// `.skipped(reason)` outcome and leaves the raw sources intact, so a meeting
/// always completes even when cleaning is unavailable or fails.
final class MeetingCleanedMicRenderer {
    static let cleanedMicrophoneFileName = "microphone-cleaned.m4a"

    /// Sample rate the echo suppressor expects; the cleaned artifact is a derived
    /// STT input (not the playback/export `meeting.m4a`), so 16 kHz mono is fine.
    static let renderSampleRate = 16_000

    private static let logger = Logger(
        subsystem: "com.macparakeet.core", category: "MeetingCleanedMicRenderer")

    struct Result: Sendable, Equatable {
        let outputURL: URL
        let durationSeconds: Double
        /// Frames the processor cleaned vs. served raw (a processor that throws
        /// falls back to raw). Emitted as diagnostics for U9 QA and telemetry,
        /// not a routing gate — U4 prefers the cleaned mic purely on its
        /// existence on disk (see `outputToRawRmsRatio`).
        let processedFrames: Int
        let rawFallbackFrames: Int
        let processingFailures: Int
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
        case decodeFailed(String)
        case renderFailed(String)
    }

    enum Outcome: Sendable, Equatable {
        case rendered(Result)
        case skipped(SkipReason)
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Render the cleaned mic. `conditioner` is the live factory's product; the
    /// caller passes a freshly built one. Synchronous: do blocking decode/encode
    /// off the main actor.
    func render(
        microphoneURL: URL,
        systemURL: URL,
        sourceAlignment: MeetingSourceAlignment,
        outputURL: URL,
        conditioner: any MicConditioning
    ) -> Outcome {
        // Only derive when a real echo processor loaded. Passthrough (no assets)
        // and unavailable (load failed) both leave the raw mic as the truth.
        let diagnostics = conditioner.diagnostics
        guard diagnostics.loaded,
              diagnostics.processorName != PassthroughMicConditioner().diagnostics.processorName else {
            return .skipped(.conditionerUnavailable)
        }
        guard fileManager.fileExists(atPath: microphoneURL.path) else {
            return .skipped(.missingMicrophoneSource)
        }
        guard fileManager.fileExists(atPath: systemURL.path) else {
            return .skipped(.missingSystemReference)
        }

        let microphone: [Float]
        let system: [Float]
        do {
            microphone = try Self.decodeMonoFloat(url: microphoneURL, sampleRate: Self.renderSampleRate)
            system = try Self.decodeMonoFloat(url: systemURL, sampleRate: Self.renderSampleRate)
        } catch {
            return .skipped(.decodeFailed(String(describing: error)))
        }
        guard !microphone.isEmpty else { return .skipped(.emptyMicrophone) }

        let conditioned = Self.alignAndCondition(
            microphone: microphone,
            system: system,
            microphoneStartOffsetMs: sourceAlignment.microphone?.startOffsetMs ?? 0,
            systemStartOffsetMs: sourceAlignment.system?.startOffsetMs ?? 0,
            sampleRate: Self.renderSampleRate,
            conditioner: conditioner)

        do {
            try Self.encodeMonoFloat(
                conditioned.output, sampleRate: Self.renderSampleRate, to: outputURL,
                fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            return .skipped(.renderFailed(String(describing: error)))
        }

        let duration = Double(conditioned.output.count) / Double(Self.renderSampleRate)
        let ratio = Self.rmsRatio(conditioned.output, microphone)
        Self.logger.info(
            "meeting_cleaned_mic_rendered duration_s=\(duration, format: .fixed(precision: 1), privacy: .public) processed_frames=\(conditioned.processedFrames, privacy: .public) raw_fallback_frames=\(conditioned.rawFallbackFrames, privacy: .public) failures=\(conditioned.processingFailures, privacy: .public) rms_ratio=\(ratio, format: .fixed(precision: 2), privacy: .public)")
        return .rendered(Result(
            outputURL: outputURL,
            durationSeconds: duration,
            processedFrames: conditioned.processedFrames,
            rawFallbackFrames: conditioned.rawFallbackFrames,
            processingFailures: conditioned.processingFailures,
            outputToRawRmsRatio: ratio))
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
    ) -> ConditionedOutput {
        conditioner.reset()
        // Place the system reference on the microphone's timeline: a sample at
        // mic position p must be cancelled against the system audio at the same
        // wall-clock instant. relativeShift > 0 means system started later than
        // the mic, so the mic's opening has no reference (leading zeros); < 0
        // means system started earlier, so its head is dropped.
        let sampleRate = max(1, sampleRate)
        let relativeShiftSamples = Int(
            (Double(systemStartOffsetMs - microphoneStartOffsetMs) / 1000.0
                * Double(sampleRate)).rounded())
        let alignedReference = shiftReference(
            system, by: relativeShiftSamples, toMatchCount: microphone.count)

        var output: [Float] = []
        output.reserveCapacity(microphone.count)
        let chunkSize = 4_096
        var cursor = 0
        while cursor < microphone.count {
            let end = min(cursor + chunkSize, microphone.count)
            let micChunk = Array(microphone[cursor..<end])
            let refChunk = Array(alignedReference[cursor..<end])
            output += conditioner.condition(
                microphone: micChunk, speaker: refChunk, hasSpeakerReference: true)
            cursor = end
        }
        output += conditioner.flush()
        // `flush()` rounds the final partial frame up, so the conditioner can
        // emit a few samples past the mic length; trim them so the cleaned file
        // is never longer than the raw mic (the 1:1 guarantee above) and its
        // reported duration matches the source.
        if output.count > microphone.count {
            output.removeLast(output.count - microphone.count)
        }

        let diagnostics = conditioner.diagnostics
        return ConditionedOutput(
            output: output,
            processedFrames: diagnostics.processedFrames,
            rawFallbackFrames: diagnostics.rawFallbackFrames,
            processingFailures: diagnostics.processingFailures)
    }

    /// Reposition `reference` so index i lines up with the microphone's index i,
    /// padding/truncating to exactly `count` samples (the reference is read at the
    /// mic's own position; the conditioner applies the echo-path delay on top).
    private static func shiftReference(
        _ reference: [Float], by shiftSamples: Int, toMatchCount count: Int
    ) -> [Float] {
        var aligned = [Float](repeating: 0, count: count)
        // Destination index d corresponds to source index (d - shiftSamples).
        for d in 0..<count {
            let s = d - shiftSamples
            if s >= 0, s < reference.count {
                aligned[d] = reference[s]
            }
        }
        return aligned
    }

    private static func rmsRatio(_ a: [Float], _ b: [Float]) -> Float {
        func power(_ s: [Float]) -> Double {
            guard !s.isEmpty else { return 0 }
            var acc = 0.0
            for v in s { acc += Double(v) * Double(v) }
            return acc / Double(s.count)
        }
        let bp = power(b)
        guard bp > 0 else { return 0 }
        return Float((power(a) / bp).squareRoot())
    }

    // MARK: Audio I/O

    /// Decode an audio file to mono Float32 at `sampleRate`, fully in memory.
    /// Peak scales with meeting length (~230 MB/hour/track at 16 kHz), which is
    /// acceptable for a bounded, off-actor, post-stop one-shot render. If
    /// multi-hour meetings prove this too heavy, stream decode→condition→encode
    /// in chunks instead (deferred; the path is inert until U5 bundles assets).
    static func decodeMonoFloat(url: URL, sampleRate: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingAudioError.storageFailed("invalid decode format")
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw MeetingAudioError.storageFailed("decode converter unavailable")
        }

        var samples: [Float] = []
        let sourceRate = file.processingFormat.sampleRate
        let ratio = targetFormat.sampleRate / max(sourceRate, 1)
        let readFrames: AVAudioFrameCount = 16_384
        var reachedEnd = false

        while !reachedEnd {
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: readFrames
            ) else {
                throw MeetingAudioError.storageFailed("decode input buffer alloc failed")
            }
            try file.read(into: inputBuffer, frameCount: readFrames)
            let providedFrames = inputBuffer.frameLength
            if providedFrames == 0 { break }

            let capacity = AVAudioFrameCount(Double(providedFrames) * ratio) + 64
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: max(capacity, 1)
            ) else {
                throw MeetingAudioError.storageFailed("decode output buffer alloc failed")
            }

            var consumed = false
            var conversionError: NSError?
            let inputWrapper = UncheckedSendableAudioPCMBuffer(inputBuffer)
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inputWrapper.buffer
            }
            if status == .error {
                throw MeetingAudioError.storageFailed(
                    conversionError?.localizedDescription ?? "decode conversion failed")
            }
            if let channel = outputBuffer.floatChannelData?.pointee {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channel, count: Int(outputBuffer.frameLength)))
            }
            if providedFrames < readFrames { reachedEnd = true }
        }

        // Flush any samples the converter is holding (e.g. resampler tail).
        if let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: readFrames) {
            var flushError: NSError?
            let status = converter.convert(to: outputBuffer, error: &flushError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if status != .error, let channel = outputBuffer.floatChannelData?.pointee,
               outputBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channel, count: Int(outputBuffer.frameLength)))
            }
        }
        return samples
    }

    /// Encode mono Float32 samples to an AAC `.m4a` at `sampleRate`.
    static func encodeMonoFloat(
        _ samples: [Float], sampleRate: Int, to outputURL: URL, fileManager: FileManager
    ) throws {
        try? fileManager.removeItem(at: outputURL)
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
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
        writer.startSession(atSourceTime: .zero)

        let sampleBufferFactory = PCMBufferToSampleBuffer()
        let blockFrames = 16_384
        var written: Int64 = 0
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + blockFrames, samples.count)
            let frameCount = AVAudioFrameCount(end - cursor)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount),
                  let channel = buffer.floatChannelData?.pointee else {
                throw MeetingAudioError.storageFailed("cleaned mic buffer alloc failed")
            }
            buffer.frameLength = frameCount
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress! + cursor, count: Int(frameCount))
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
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard input.append(sampleBuffer) else {
                throw MeetingAudioError.storageFailed(
                    writer.error?.localizedDescription ?? "cleaned mic append failed")
            }
            written += Int64(frameCount)
            cursor = end
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(writer)
        writer.finishWriting {
            semaphore.signal()
            _ = box
        }
        semaphore.wait()
        if writer.status == .failed {
            throw MeetingAudioError.storageFailed(
                writer.error?.localizedDescription ?? "cleaned mic finalize failed")
        }
    }
}

/// Minimal Sendable box so the non-Sendable `AVAssetWriter` can be referenced
/// from `finishWriting`'s `@Sendable` completion without capturing `self`.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

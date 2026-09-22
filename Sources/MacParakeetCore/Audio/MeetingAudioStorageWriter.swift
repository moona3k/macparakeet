import Accelerate
import AVFoundation
import Foundation
import os
import OSLog

/// AVAssetWriter's finish callback is @Sendable, but the object itself is
/// non-Sendable. This wrapper is limited to reading the writer's final error
/// from AVFoundation's own completion callback after writes have stopped.
private final class FinalizedAVAssetWriter: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

/// Process-local guard against recovery or discard reading source files while
/// AVAssetWriter still owns their finalization. A process restart clears the
/// registry only after macOS has closed every writer file descriptor.
enum MeetingAudioWriterFinalizationRegistry {
    private static let folders = OSAllocatedUnfairLock(initialState: Set<String>())

    static func begin(folderURL: URL) {
        _ = folders.withLock { $0.insert(folderURL.standardizedFileURL.path) }
    }

    static func end(folderURL: URL) {
        _ = folders.withLock { $0.remove(folderURL.standardizedFileURL.path) }
    }

    static func contains(folderURL: URL) -> Bool {
        folders.withLock { $0.contains(folderURL.standardizedFileURL.path) }
    }
}

/// Non-Sendable audio sink owned and serialized by MeetingRecordingService.
/// Its AVFoundation writer/converter objects are mutable reference types.
final class MeetingAudioStorageWriter {
    private enum InputReadinessPolicy: Equatable {
        case failFast
        case boundedRecoveryGap
    }

    /// Recovery padding is produced much faster than real time. Give
    /// AVAssetWriter a short, bounded window to drain between synthetic
    /// chunks without weakening the fail-before-drop policy for live audio.
    private static let recoveryGapBackpressureTimeout: TimeInterval = 0.25
    private static let recoveryGapBackpressurePollInterval: TimeInterval = 0.001
    /// Match the existing five-second capture teardown boundary.
    private static let finalizationTimeout: TimeInterval = 5

    struct FinalizationReport: Sendable, Equatable {
        let failedSources: Set<AudioSource>
        /// Sources still owned by AVFoundation at the deadline, even when
        /// empty. Consumers must neither inspect them nor remove their folder.
        let timedOutSources: Set<AudioSource>

        init(failedSources: Set<AudioSource>, timedOutSources: Set<AudioSource> = []) {
            self.failedSources = failedSources
            self.timedOutSources = timedOutSources
        }
    }

    /// Callback ownership and the deadline arbitrate in the same transition.
    /// A timeout delivers a report, but only the last callback releases the folder.
    final class FinalizationCoordinator: Sendable {
        private struct State {
            var pendingSources: Set<AudioSource> = [.microphone, .system]
            var failedSources: Set<AudioSource> = []
            var reportDelivered = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let writtenFrameCounts: [AudioSource: Int64]
        private let folderURL: URL

        init(folderURL: URL, writtenFrameCounts: [AudioSource: Int64]) {
            self.folderURL = folderURL
            self.writtenFrameCounts = writtenFrameCounts
            MeetingAudioWriterFinalizationRegistry.begin(folderURL: folderURL)
        }

        func sourceDidFinish(_ source: AudioSource, failed: Bool) -> FinalizationReport? {
            state.withLock { state in
                guard state.pendingSources.remove(source) != nil else { return nil }
                if failed {
                    state.failedSources.insert(source)
                }
                guard state.pendingSources.isEmpty else { return nil }
                MeetingAudioWriterFinalizationRegistry.end(folderURL: folderURL)
                guard !state.reportDelivered else { return nil }
                state.reportDelivered = true
                return FinalizationReport(failedSources: state.failedSources)
            }
        }

        func deadlineExpired() -> FinalizationReport? {
            state.withLock { state in
                guard !state.reportDelivered, !state.pendingSources.isEmpty else { return nil }
                state.reportDelivered = true
                state.failedSources.formUnion(
                    state.pendingSources.filter { writtenFrameCounts[$0, default: 0] > 0 }
                )
                return FinalizationReport(
                    failedSources: state.failedSources,
                    timedOutSources: state.pendingSources
                )
            }
        }
    }

    struct SourceWriteMetrics: Sendable, Equatable {
        /// Frames received from the capture source. Recovery padding is not
        /// included so coverage remains an honest measure of captured audio.
        let writtenFrameCount: Int64
        /// End of the playable source timeline, including inserted silence
        /// for host-time gaps between captured buffers.
        let timelineFrameCount: Int64
        /// Effective host timeline origin for file time zero. When valid host
        /// timestamps begin after untimed audio, this is shifted backward by
        /// the duration already written so cross-source alignment matches the
        /// actual file timeline.
        let timelineOriginSeconds: TimeInterval?
        let sampleRate: Double
        /// Largest absolute sample in successfully appended, converted PCM.
        /// Unlike input-channel meters, this describes the signal retained
        /// after downmixing, without a quiet-audio threshold.
        let peakSampleMagnitude: Float
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioStorageWriter")

    private let targetFormat: AVAudioFormat
    private var microphoneWriter: AVAssetWriter?
    private var microphoneInput: AVAssetWriterInput?
    private var systemWriter: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var microphoneConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    /// PTS counter for successfully appended real and recovery-padding frames.
    private var microphoneTimelineFrames: Int64 = 0
    private var systemTimelineFrames: Int64 = 0
    /// Real capture frames appended successfully, excluding recovery padding.
    /// Used by `metrics(for:)` so coverage reports what the devices delivered.
    private var microphoneActualFrameCount: Int64 = 0
    private var systemActualFrameCount: Int64 = 0
    private var microphonePeakSampleMagnitude: Float = 0
    private var systemPeakSampleMagnitude: Float = 0
    /// Per-source host timeline origin. Each raw source starts at file time zero;
    /// cross-source initial offset remains in `MeetingSourceAlignment`.
    private var microphoneTimelineOriginSeconds: TimeInterval?
    private var systemTimelineOriginSeconds: TimeInterval?
    private let sampleBufferFactory = PCMBufferToSampleBuffer()

    let microphoneAudioURL: URL
    let systemAudioURL: URL
    let mixedAudioURL: URL
    let folderURL: URL

    init(
        folderURL: URL,
        sampleRate: Double = 48000,
        channels: AVAudioChannelCount = 1
    ) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        else {
            throw MeetingAudioError.storageFailed("invalid output format")
        }
        self.targetFormat = format
        self.folderURL = folderURL
        self.microphoneAudioURL = folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone)
        self.systemAudioURL = folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem)
        self.mixedAudioURL = folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback)

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        (microphoneWriter, microphoneInput) = try Self.makeWriter(
            outputURL: microphoneAudioURL,
            sampleRate: sampleRate,
            channels: channels
        )
        (systemWriter, systemInput) = try Self.makeWriter(
            outputURL: systemAudioURL,
            sampleRate: sampleRate,
            channels: channels
        )
    }

    func write(
        _ buffer: AVAudioPCMBuffer,
        source: AudioSource,
        timelineTimeSeconds: TimeInterval? = nil
    ) throws {
        switch source {
        case .microphone:
            try write(
                buffer,
                writer: microphoneWriter,
                input: microphoneInput,
                converter: &microphoneConverter,
                timelineFrames: &microphoneTimelineFrames,
                actualFrameCount: &microphoneActualFrameCount,
                peakSampleMagnitude: &microphonePeakSampleMagnitude,
                timelineOriginSeconds: &microphoneTimelineOriginSeconds,
                timelineTimeSeconds: timelineTimeSeconds
            )
        case .system:
            try write(
                buffer,
                writer: systemWriter,
                input: systemInput,
                converter: &systemConverter,
                timelineFrames: &systemTimelineFrames,
                actualFrameCount: &systemActualFrameCount,
                peakSampleMagnitude: &systemPeakSampleMagnitude,
                timelineOriginSeconds: &systemTimelineOriginSeconds,
                timelineTimeSeconds: timelineTimeSeconds
            )
        }
    }

    func finalize(completion: @escaping @Sendable (FinalizationReport) -> Void) {
        let microphoneWriter = self.microphoneWriter
        let microphoneInput = self.microphoneInput
        let systemWriter = self.systemWriter
        let systemInput = self.systemInput
        let microphoneActualFrameCount = self.microphoneActualFrameCount
        let systemActualFrameCount = self.systemActualFrameCount
        let logger = self.logger
        let folderURL = self.folderURL

        self.microphoneWriter = nil
        self.microphoneInput = nil
        self.systemWriter = nil
        self.systemInput = nil
        self.microphoneConverter = nil
        self.systemConverter = nil

        let finalizationCoordinator = FinalizationCoordinator(
            folderURL: folderURL,
            writtenFrameCounts: [
                .microphone: microphoneActualFrameCount,
                .system: systemActualFrameCount,
            ]
        )
        let completeOne: @Sendable (AudioSource, Bool) -> Void = { source, failed in
            let outcome = finalizationCoordinator.sourceDidFinish(source, failed: failed)
            if let outcome {
                completion(outcome)
            }
        }

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.finalizationTimeout
        ) {
            let outcome = finalizationCoordinator.deadlineExpired()
            guard let outcome else { return }
            Self.logFinalizationTimeout(
                sources: [.microphone, .system].filter(outcome.timedOutSources.contains),
                timeout: Self.finalizationTimeout,
                logger: logger
            )
            completion(outcome)
        }

        Self.finish(
            source: .microphone,
            writtenFrameCount: microphoneActualFrameCount,
            writer: microphoneWriter,
            input: microphoneInput,
            logger: logger,
            completion: completeOne
        )
        Self.finish(
            source: .system,
            writtenFrameCount: systemActualFrameCount,
            writer: systemWriter,
            input: systemInput,
            logger: logger,
            completion: completeOne
        )
    }

    static func shouldReportFinalizationFailure(
        status: AVAssetWriter.Status,
        hasError: Bool,
        writtenFrameCount: Int64
    ) -> Bool {
        writtenFrameCount > 0 && (status != .completed || hasError)
    }

    func metrics(for source: AudioSource) -> SourceWriteMetrics {
        switch source {
        case .microphone:
            return SourceWriteMetrics(
                writtenFrameCount: microphoneActualFrameCount,
                timelineFrameCount: microphoneTimelineFrames,
                timelineOriginSeconds: microphoneTimelineOriginSeconds,
                sampleRate: targetFormat.sampleRate,
                peakSampleMagnitude: microphonePeakSampleMagnitude
            )
        case .system:
            return SourceWriteMetrics(
                writtenFrameCount: systemActualFrameCount,
                timelineFrameCount: systemTimelineFrames,
                timelineOriginSeconds: systemTimelineOriginSeconds,
                sampleRate: targetFormat.sampleRate,
                peakSampleMagnitude: systemPeakSampleMagnitude
            )
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        writer: AVAssetWriter?,
        input: AVAssetWriterInput?,
        converter: inout AVAudioConverter?,
        timelineFrames: inout Int64,
        actualFrameCount: inout Int64,
        peakSampleMagnitude: inout Float,
        timelineOriginSeconds: inout TimeInterval?,
        timelineTimeSeconds: TimeInterval?
    ) throws {
        guard let writer, let input else { return }
        guard writer.status == .writing else {
            if let error = writer.error {
                throw MeetingAudioError.storageFailed(error.localizedDescription)
            }
            return
        }

        let converted = try convertIfNeeded(buffer, converter: &converter)
        var materializedRecoveryGap = false
        if let timelineTimeSeconds,
            timelineTimeSeconds.isFinite
        {
            if timelineOriginSeconds == nil {
                // If capture began with an invalid host timestamp, keep those
                // already-written frames ahead of this first valid timestamp
                // instead of silently losing them from later gap calculations.
                timelineOriginSeconds =
                    timelineTimeSeconds
                    - (Double(timelineFrames) / targetFormat.sampleRate)
            }
            if let timelineOriginSeconds {
                let elapsedSeconds = max(0, timelineTimeSeconds - timelineOriginSeconds)
                let requestedFrame = Int64((elapsedSeconds * targetFormat.sampleRate).rounded())
                let gapFrames = requestedFrame - timelineFrames
                if gapFrames > 1 {
                    try appendSilence(
                        frameCount: gapFrames,
                        writer: writer,
                        input: input,
                        timelineFrames: &timelineFrames
                    )
                    materializedRecoveryGap = true
                }
            }
        }

        try append(
            converted,
            writer: writer,
            input: input,
            timelineFrames: &timelineFrames,
            readinessPolicy: materializedRecoveryGap ? .boundedRecoveryGap : .failFast
        )
        actualFrameCount += Int64(converted.frameLength)
        // Reuse the exact Float32 PCM accepted by the writer. Scanning the
        // input would miss right-channel audio or overlook mono cancellation.
        for audioBuffer in UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList) {
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
            var bufferPeak: Float = 0
            vDSP_maxmgv(
                data.assumingMemoryBound(to: Float.self),
                1,
                &bufferPeak,
                vDSP_Length(audioBuffer.mDataByteSize) / vDSP_Length(MemoryLayout<Float>.size)
            )
            peakSampleMagnitude = max(peakSampleMagnitude, bufferPeak)
        }
    }

    private func appendSilence(
        frameCount: Int64,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        timelineFrames: inout Int64
    ) throws {
        var remainingFrames = frameCount
        let maximumChunkFrames = max(1, Int64(targetFormat.sampleRate * 30))

        while remainingFrames > 0 {
            let chunkFrames = AVAudioFrameCount(min(remainingFrames, maximumChunkFrames))
            guard
                let silence = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: chunkFrames
                )
            else {
                throw MeetingAudioError.storageFailed("failed to allocate timeline padding")
            }
            silence.frameLength = chunkFrames
            if let channels = silence.floatChannelData {
                for channel in 0..<Int(targetFormat.channelCount) {
                    channels[channel].update(repeating: 0, count: Int(chunkFrames))
                }
            }
            try append(
                silence,
                writer: writer,
                input: input,
                timelineFrames: &timelineFrames,
                readinessPolicy: .boundedRecoveryGap
            )
            remainingFrames -= Int64(chunkFrames)
        }
    }

    private func append(
        _ buffer: AVAudioPCMBuffer,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        timelineFrames: inout Int64,
        readinessPolicy: InputReadinessPolicy
    ) throws {
        if !input.isReadyForMoreMediaData,
            readinessPolicy == .boundedRecoveryGap
        {
            let deadline =
                DispatchTime.now()
                + Self.recoveryGapBackpressureTimeout
            while !input.isReadyForMoreMediaData,
                writer.status == .writing,
                DispatchTime.now() < deadline
            {
                Thread.sleep(forTimeInterval: Self.recoveryGapBackpressurePollInterval)
            }
        }

        guard writer.status == .writing else {
            throw MeetingAudioError.storageFailed(
                writer.error?.localizedDescription ?? "audio writer stopped"
            )
        }
        guard input.isReadyForMoreMediaData else {
            logger.error(
                "Meeting audio writer input not ready, failing capture before dropping \(buffer.frameLength, privacy: .public) frames"
            )
            throw MeetingAudioError.storageFailed("audio writer backpressure")
        }

        let sampleBuffer = try sampleBufferFactory.makeSampleBuffer(
            from: buffer,
            presentationTimeSamples: timelineFrames
        )
        guard input.append(sampleBuffer) else {
            throw MeetingAudioError.storageFailed(writer.error?.localizedDescription ?? "append failed")
        }
        timelineFrames += Int64(buffer.frameLength)
    }

    private func convertIfNeeded(
        _ sourceBuffer: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?
    ) throws -> AVAudioPCMBuffer {
        let buffer: AVAudioPCMBuffer
        if targetFormat.channelCount == 1, sourceBuffer.format.channelCount > 1 {
            // AVAudioConverter's default channel map can select channel zero
            // instead of mixing. Retained mono must include every input channel.
            guard let mono = downmixChannelsToMono(from: sourceBuffer) else {
                throw MeetingAudioError.storageFailed("failed to downmix source audio")
            }
            buffer = mono
        } else {
            buffer = sourceBuffer
        }
        if !needsConversion(from: buffer.format) {
            return buffer
        }

        if converter == nil || converter?.inputFormat.isEqual(buffer.format) == false {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }

        guard let converter else {
            throw MeetingAudioError.storageFailed("audio converter unavailable")
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw MeetingAudioError.storageFailed("failed to allocate output buffer")
        }

        var error: NSError?
        let inputBuffer = UncheckedSendableAudioPCMBuffer(buffer)
        let provided = OSAllocatedUnfairLock(initialState: false)
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            let shouldProvideInput = provided.withLock { didProvide -> Bool in
                guard !didProvide else { return false }
                didProvide = true
                return true
            }
            if !shouldProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return inputBuffer.buffer
        }

        if status == .error {
            if let error {
                logger.error(
                    "meeting_audio_conversion_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
            } else {
                logger.error("meeting_audio_conversion_failed error_type=unknown")
            }
            throw MeetingAudioError.storageFailed(error?.localizedDescription ?? "conversion failed")
        }

        return output
    }

    private func needsConversion(from format: AVAudioFormat) -> Bool {
        format.sampleRate != targetFormat.sampleRate
            || format.channelCount != targetFormat.channelCount
            || format.commonFormat != targetFormat.commonFormat
    }

    private static func makeWriter(
        outputURL: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws -> (AVAssetWriter, AVAssetWriterInput) {
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        writer.initialMovieFragmentInterval = CMTime(value: 1, timescale: 1)
        writer.shouldOptimizeForNetworkUse = false

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw MeetingAudioError.storageFailed("AVAssetWriter cannot add audio input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MeetingAudioError.storageFailed(writer.error?.localizedDescription ?? "AVAssetWriter start failed")
        }
        writer.startSession(atSourceTime: .zero)

        return (writer, input)
    }

    private static func finish(
        source: AudioSource,
        writtenFrameCount: Int64,
        writer: AVAssetWriter?,
        input: AVAssetWriterInput?,
        logger: Logger,
        completion: @escaping @Sendable (AudioSource, Bool) -> Void
    ) {
        guard let writer else {
            completion(source, false)
            return
        }
        guard writer.status == .writing else {
            let failed = shouldReportFinalizationFailure(
                status: writer.status,
                hasError: writer.error != nil,
                writtenFrameCount: writtenFrameCount
            )
            if failed {
                logFinalizationFailure(writer: writer, source: source, logger: logger)
            }
            completion(source, failed)
            return
        }

        input?.markAsFinished()
        let finalizedWriter = FinalizedAVAssetWriter(writer)
        finalizedWriter.writer.finishWriting {
            let writer = finalizedWriter.writer
            let failed = shouldReportFinalizationFailure(
                status: writer.status,
                hasError: writer.error != nil,
                writtenFrameCount: writtenFrameCount
            )
            if failed {
                logFinalizationFailure(writer: writer, source: source, logger: logger)
            }
            completion(source, failed)
        }
    }

    private static func logFinalizationTimeout(
        sources: [AudioSource],
        timeout: TimeInterval,
        logger: Logger
    ) {
        let sourceNames = sources.map(\.rawValue).joined(separator: ",")
        let timeoutDescription = String(format: "%.3f", timeout)
        logger.error(
            "meeting_audio_writer_finalize_timed_out sources=\(sourceNames, privacy: .public) timeout_s=\(timeoutDescription, privacy: .public)"
        )
        AudioCaptureDiagnostics.append(
            "meeting_audio_writer_finalize_timeout sources=\(sourceNames) timeout_s=\(timeoutDescription)"
        )
    }

    private static func logFinalizationFailure(
        writer: AVAssetWriter,
        source: AudioSource,
        logger: Logger
    ) {
        if let error = writer.error {
            logger.error(
                "meeting_audio_writer_finalize_failed source=\(source.rawValue, privacy: .public) status=\(writer.status.rawValue, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
        } else {
            logger.error(
                "meeting_audio_writer_finalize_failed source=\(source.rawValue, privacy: .public) status=\(writer.status.rawValue, privacy: .public) error_type=unknown"
            )
        }
    }
}

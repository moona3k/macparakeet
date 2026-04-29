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

/// Non-Sendable audio sink owned and serialized by MeetingRecordingService.
/// Its AVFoundation writer/converter objects are mutable reference types.
final class MeetingAudioStorageWriter {
    struct SourceWriteMetrics: Sendable, Equatable {
        let writtenFrameCount: Int64
        let sampleRate: Double
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioStorageWriter")

    private let targetFormat: AVAudioFormat
    private var microphoneWriter: AVAssetWriter?
    private var microphoneInput: AVAssetWriterInput?
    private var systemWriter: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var microphoneConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    /// PTS counter for successfully appended buffers.
    private var microphoneWrittenFrames: Int64 = 0
    private var systemWrittenFrames: Int64 = 0
    /// Frames actually appended to the writer input (success path only).
    /// Used by `metrics(for:)` so the source-alignment metadata reports
    /// what's truly on disk.
    private var microphoneActualFrameCount: Int64 = 0
    private var systemActualFrameCount: Int64 = 0
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
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw MeetingAudioError.storageFailed("invalid output format")
        }
        self.targetFormat = format
        self.folderURL = folderURL
        self.microphoneAudioURL = folderURL.appendingPathComponent("microphone.m4a")
        self.systemAudioURL = folderURL.appendingPathComponent("system.m4a")
        self.mixedAudioURL = folderURL.appendingPathComponent("meeting.m4a")

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

    func write(_ buffer: AVAudioPCMBuffer, source: AudioSource) throws {
        switch source {
        case .microphone:
            try write(
                buffer,
                writer: microphoneWriter,
                input: microphoneInput,
                converter: &microphoneConverter,
                writtenFrames: &microphoneWrittenFrames,
                actualFrameCount: &microphoneActualFrameCount
            )
        case .system:
            try write(
                buffer,
                writer: systemWriter,
                input: systemInput,
                converter: &systemConverter,
                writtenFrames: &systemWrittenFrames,
                actualFrameCount: &systemActualFrameCount
            )
        }
    }

    func finalize(completion: @escaping @Sendable () -> Void) {
        let microphoneWriter = self.microphoneWriter
        let microphoneInput = self.microphoneInput
        let systemWriter = self.systemWriter
        let systemInput = self.systemInput
        let logger = self.logger

        self.microphoneWriter = nil
        self.microphoneInput = nil
        self.systemWriter = nil
        self.systemInput = nil
        self.microphoneConverter = nil
        self.systemConverter = nil

        let remainingFinishes = OSAllocatedUnfairLock(initialState: 2)
        let completeOne: @Sendable () -> Void = {
            let shouldComplete = remainingFinishes.withLock { remaining in
                remaining -= 1
                return remaining == 0
            }
            if shouldComplete {
                completion()
            }
        }
        Self.finish(writer: microphoneWriter, input: microphoneInput, logger: logger, completion: completeOne)
        Self.finish(writer: systemWriter, input: systemInput, logger: logger, completion: completeOne)
    }

    func metrics(for source: AudioSource) -> SourceWriteMetrics {
        switch source {
        case .microphone:
            return SourceWriteMetrics(
                writtenFrameCount: microphoneActualFrameCount,
                sampleRate: targetFormat.sampleRate
            )
        case .system:
            return SourceWriteMetrics(
                writtenFrameCount: systemActualFrameCount,
                sampleRate: targetFormat.sampleRate
            )
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        writer: AVAssetWriter?,
        input: AVAssetWriterInput?,
        converter: inout AVAudioConverter?,
        writtenFrames: inout Int64,
        actualFrameCount: inout Int64
    ) throws {
        guard let writer, let input else { return }
        guard writer.status == .writing else {
            if let error = writer.error {
                throw MeetingAudioError.storageFailed(error.localizedDescription)
            }
            return
        }

        let converted = try convertIfNeeded(buffer, converter: &converter)
        guard input.isReadyForMoreMediaData else {
            logger.error("Meeting audio writer input not ready, failing capture before dropping \(converted.frameLength, privacy: .public) frames")
            throw MeetingAudioError.storageFailed("audio writer backpressure")
        }

        let sampleBuffer = try sampleBufferFactory.makeSampleBuffer(
            from: converted,
            presentationTimeSamples: writtenFrames
        )
        guard input.append(sampleBuffer) else {
            throw MeetingAudioError.storageFailed(writer.error?.localizedDescription ?? "append failed")
        }

        writtenFrames += Int64(converted.frameLength)
        actualFrameCount += Int64(converted.frameLength)
    }

    private func convertIfNeeded(
        _ buffer: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?
    ) throws -> AVAudioPCMBuffer {
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
            logger.error("Meeting audio conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
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
        writer: AVAssetWriter?,
        input: AVAssetWriterInput?,
        logger: Logger,
        completion: @escaping @Sendable () -> Void
    ) {
        guard let writer else {
            completion()
            return
        }
        guard writer.status == .writing else {
            completion()
            return
        }

        input?.markAsFinished()
        let finalizedWriter = FinalizedAVAssetWriter(writer)
        finalizedWriter.writer.finishWriting {
            if let error = finalizedWriter.writer.error {
                logger.error("meeting_audio_writer_finalize_failed error=\(error.localizedDescription, privacy: .public)")
            }
            completion()
        }
    }
}

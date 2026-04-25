import AVFoundation
import Foundation
import OSLog

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
    private var microphoneWrittenFrames: Int64 = 0
    private var systemWrittenFrames: Int64 = 0
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
                writtenFrames: &microphoneWrittenFrames
            )
        case .system:
            try write(
                buffer,
                writer: systemWriter,
                input: systemInput,
                converter: &systemConverter,
                writtenFrames: &systemWrittenFrames
            )
        }
    }

    func finalize() {
        finish(writer: microphoneWriter, input: microphoneInput)
        finish(writer: systemWriter, input: systemInput)
        microphoneWriter = nil
        microphoneInput = nil
        systemWriter = nil
        systemInput = nil
        microphoneConverter = nil
        systemConverter = nil
    }

    func metrics(for source: AudioSource) -> SourceWriteMetrics {
        switch source {
        case .microphone:
            return SourceWriteMetrics(
                writtenFrameCount: microphoneWrittenFrames,
                sampleRate: targetFormat.sampleRate
            )
        case .system:
            return SourceWriteMetrics(
                writtenFrameCount: systemWrittenFrames,
                sampleRate: targetFormat.sampleRate
            )
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        writer: AVAssetWriter?,
        input: AVAssetWriterInput?,
        converter: inout AVAudioConverter?,
        writtenFrames: inout Int64
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
            throw MeetingAudioError.storageFailed("AVAssetWriter input is not ready for more media data")
        }

        let sampleBuffer = try sampleBufferFactory.makeSampleBuffer(
            from: converted,
            presentationTimeSamples: writtenFrames
        )
        guard input.append(sampleBuffer) else {
            throw MeetingAudioError.storageFailed(writer.error?.localizedDescription ?? "append failed")
        }

        writtenFrames += Int64(converted.frameLength)
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
        var provided = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
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

    private func finish(writer: AVAssetWriter?, input: AVAssetWriterInput?) {
        guard let writer else { return }
        guard writer.status == .writing else { return }

        input?.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting {
            group.leave()
        }
        group.wait()

        if let error = writer.error {
            logger.error("meeting_audio_writer_finalize_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

import AVFAudio
import Foundation
import OSLog

final class MeetingAudioStorageWriter {
    struct SourceWriteMetrics: Sendable, Equatable {
        let writtenFrameCount: Int64
        let sampleRate: Double
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioStorageWriter")

    private let targetFormat: AVAudioFormat
    private var microphoneFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var microphoneConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    private var microphoneWrittenFrames: Int64 = 0
    private var systemWrittenFrames: Int64 = 0

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

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64000,
        ]

        microphoneFile = try AVAudioFile(
            forWriting: microphoneAudioURL,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: false
        )
        systemFile = try AVAudioFile(
            forWriting: systemAudioURL,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: false
        )
    }

    func write(_ buffer: AVAudioPCMBuffer, source: AudioSource) throws {
        switch source {
        case .microphone:
            try write(
                buffer,
                to: &microphoneFile,
                converter: &microphoneConverter,
                writtenFrames: &microphoneWrittenFrames
            )
        case .system:
            try write(
                buffer,
                to: &systemFile,
                converter: &systemConverter,
                writtenFrames: &systemWrittenFrames
            )
        }
    }

    func finalize() {
        microphoneFile = nil
        systemFile = nil
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
        to file: inout AVAudioFile?,
        converter: inout AVAudioConverter?,
        writtenFrames: inout Int64
    ) throws {
        guard let file else { return }
        let converted = try convertIfNeeded(buffer, converter: &converter)
        try file.write(from: converted)
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
}

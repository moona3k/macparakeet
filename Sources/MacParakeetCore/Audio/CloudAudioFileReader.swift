import AVFAudio
import Foundation

/// A pull reader: an empty batch means EOF, and no read may exceed its request.
protocol CloudAudioSampleReading: Sendable {
    var estimatedSampleCount: Int { get async }
    func read(maxSamples: Int) async throws -> [Float]
}

/// File decoding stays on this actor, with one persistent converter so rate
/// conversion retains its filter state across upload boundaries. Neither this
/// reader nor its caller starts a producer that can run ahead of an upload.
actor CloudAudioFileReader: CloudAudioSampleReading {
    static let sampleRate = 16_000.0
    static let maxReadSamples = 16_384
    let estimatedSampleCount: Int

    enum ReadError: Error, LocalizedError {
        case unsupportedFormat, allocationFailed, conversionFailed, noProgress, invalidBatch

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "The recording's audio format is not supported."
            case .allocationFailed: return "Could not allocate an audio conversion buffer."
            case .conversionFailed: return "Could not convert the recording's audio."
            case .noProgress: return "Audio decoding stopped before reaching the end of the recording."
            case .invalidBatch: return "The audio reader returned an invalid sample batch."
            }
        }
    }

    /// AVAudioConverter calls its input block synchronously. This state is
    /// accessed only by the reader actor during that call; the wrapper makes
    /// the SDK's @Sendable callback boundary explicit.
    private final class Input: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var error: Error?
        var ended = false

        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
            self.file = file
            self.buffer = buffer
        }

        func supply(_ requested: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>)
            -> AVAudioBuffer?
        {
            guard !ended, error == nil else { status.pointee = .endOfStream; return nil }
            do {
                try Task.checkCancellation()
                guard file.framePosition < file.length else {
                    ended = true
                    status.pointee = .endOfStream
                    return nil
                }
                guard requested > 0 else { throw ReadError.noProgress }
                let remaining = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition))
                try file.read(into: buffer, frameCount: min(requested, remaining))
                guard buffer.frameLength > 0 else {
                    // A zero read before the advertised end is corruption or
                    // a stalled decoder, not a successful shortened recording.
                    throw ReadError.noProgress
                }
                status.pointee = .haveData
                return buffer
            } catch {
                self.error = error
                status.pointee = .endOfStream
                return nil
            }
        }
    }

    private let input: Input
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var ended = false

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0,
            (1...64).contains(format.channelCount), file.length >= 0,
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: format, to: output)
        else { throw ReadError.unsupportedFormat }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw ReadError.allocationFailed
        }
        converter.downmix = true
        self.converter = converter
        outputFormat = output
        input = Input(file: file, buffer: buffer)
        let estimate = (Double(file.length) * Self.sampleRate / format.sampleRate).rounded(.up)
        estimatedSampleCount = Int(exactly: estimate) ?? Int.max
    }

    func read(maxSamples: Int) throws -> [Float] {
        try Task.checkCancellation()
        guard maxSamples > 0 else { throw ReadError.invalidBatch }
        guard !ended else { return [] }
        let capacity = AVAudioFrameCount(min(maxSamples, Self.maxReadSamples))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ReadError.allocationFailed
        }
        while true {
            try Task.checkCancellation()
            let previousPosition = input.file.framePosition
            let input = self.input
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, status in
                input.supply(requested, status: status)
            }
            if let error = input.error { throw error }
            if let error { throw error }
            guard status != .error else { throw ReadError.conversionFailed }
            try Task.checkCancellation()
            if status == .endOfStream { ended = true }
            if output.frameLength > 0 {
                guard let samples = output.floatChannelData?[0] else { throw ReadError.conversionFailed }
                return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            }
            if ended { return [] }
            guard input.file.framePosition > previousPosition else { throw ReadError.noProgress }
        }
    }
}

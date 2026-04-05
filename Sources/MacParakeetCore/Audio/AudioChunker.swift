import AVFAudio
import Foundation

/// Buffers resampled audio and emits chunks suitable for incremental STT.
public actor AudioChunker {
    public struct AudioChunk: Sendable, Equatable {
        public let samples: [Float]
        public let startMs: Int
        public let endMs: Int

        public var durationMs: Int { endMs - startMs }

        public init(samples: [Float], startMs: Int, endMs: Int) {
            self.samples = samples
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    public let targetSampleRate: Int = 16000
    public let chunkDuration: TimeInterval = 5.0
    public let overlapDuration: TimeInterval = 1.0
    public let minimumSamples: Int = 8000

    private var buffer: [Float] = []
    private var totalSamplesProcessed: Int = 0

    public init() {}

    private var chunkSize: Int {
        Int(Double(targetSampleRate) * chunkDuration)
    }

    private var overlapSize: Int {
        Int(Double(targetSampleRate) * overlapDuration)
    }

    public var currentPositionMs: Int {
        (totalSamplesProcessed * 1000) / targetSampleRate
    }

    public func addSamples(_ samples: [Float]) -> AudioChunk? {
        buffer.append(contentsOf: samples)

        guard buffer.count >= chunkSize else {
            return nil
        }

        let chunkSamples = Array(buffer.prefix(chunkSize))
        let endMs = (totalSamplesProcessed + chunkSize) * 1000 / targetSampleRate
        let startMs = endMs - Int(chunkDuration * 1000)

        let samplesToRemove = chunkSize - overlapSize
        buffer = Array(buffer.dropFirst(samplesToRemove))
        totalSamplesProcessed += samplesToRemove

        return AudioChunk(
            samples: chunkSamples,
            startMs: max(0, startMs),
            endMs: endMs
        )
    }

    public func flush() -> AudioChunk? {
        guard buffer.count >= minimumSamples else {
            buffer = []
            return nil
        }

        let chunkSamples = buffer
        let chunkDurationMs = (chunkSamples.count * 1000) / targetSampleRate
        let startMs = currentPositionMs
        let endMs = startMs + chunkDurationMs

        buffer = []
        totalSamplesProcessed += chunkSamples.count

        return AudioChunk(
            samples: chunkSamples,
            startMs: startMs,
            endMs: endMs
        )
    }

    public func reset() {
        buffer = []
        totalSamplesProcessed = 0
    }

    public var bufferSampleCount: Int {
        buffer.count
    }
}

public extension AudioChunker {
    static func resample(
        samples: [Float],
        fromRate sourceRate: Int,
        toRate targetRate: Int = 16000
    ) -> [Float] {
        guard sourceRate != targetRate else { return samples }
        guard !samples.isEmpty else { return [] }

        let ratio = Double(sourceRate) / Double(targetRate)
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let sourceIndex = Double(index) * ratio
            let floorIndex = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(floorIndex))

            if floorIndex + 1 < samples.count {
                output[index] = samples[floorIndex] * (1 - fraction) + samples[floorIndex + 1] * fraction
            } else {
                output[index] = samples[min(floorIndex, samples.count - 1)]
            }
        }

        return output
    }

    static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }

        if let channelData = buffer.floatChannelData {
            return downmixFloatChannels(channelData, frameCount: frameCount, channelCount: channelCount)
        }

        if let channelData = buffer.int16ChannelData {
            return downmixInt16Channels(channelData, frameCount: frameCount, channelCount: channelCount)
        }

        return nil
    }

    static func extractAndResample(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let samples = extractSamples(from: buffer) else { return nil }
        return resample(samples: samples, fromRate: Int(buffer.format.sampleRate))
    }

    private static func downmixFloatChannels(
        _ channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        var mixed = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<channelCount {
            let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount)
            for frameIndex in 0..<frameCount {
                mixed[frameIndex] += channel[frameIndex]
            }
        }

        let scale = 1 / Float(channelCount)
        for frameIndex in 0..<frameCount {
            mixed[frameIndex] *= scale
        }
        return mixed
    }

    private static func downmixInt16Channels(
        _ channelData: UnsafePointer<UnsafeMutablePointer<Int16>>,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount)).map {
                Float($0) / Float(Int16.max)
            }
        }

        var mixed = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<channelCount {
            let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount)
            for frameIndex in 0..<frameCount {
                mixed[frameIndex] += Float(channel[frameIndex]) / Float(Int16.max)
            }
        }

        let scale = 1 / Float(channelCount)
        for frameIndex in 0..<frameCount {
            mixed[frameIndex] *= scale
        }
        return mixed
    }
}

import AVFoundation
import CoreMedia
import Foundation

public enum PCMBufferToSampleBufferError: Error, Equatable, LocalizedError {
    case emptyBuffer
    case negativePresentationTimeSamples(Int64)
    case invalidSampleRate(Double)
    case audioFormatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case dataBufferCreationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyBuffer:
            return "Cannot create a sample buffer from an empty PCM buffer."
        case .negativePresentationTimeSamples(let samples):
            return "Presentation time samples must be non-negative: \(samples)."
        case .invalidSampleRate(let sampleRate):
            return "PCM buffer sample rate is not a supported integer rate: \(sampleRate)."
        case .audioFormatDescriptionCreationFailed(let status):
            return "Failed to create audio format description: \(status)."
        case .sampleBufferCreationFailed(let status):
            return "Failed to create sample buffer: \(status)."
        case .dataBufferCreationFailed(let status):
            return "Failed to copy PCM audio into sample buffer: \(status)."
        }
    }
}

public struct PCMBufferToSampleBuffer {
    public init() {}

    public func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTimeSamples: Int64
    ) throws -> CMSampleBuffer {
        guard buffer.frameLength > 0 else {
            throw PCMBufferToSampleBufferError.emptyBuffer
        }
        guard presentationTimeSamples >= 0 else {
            throw PCMBufferToSampleBufferError.negativePresentationTimeSamples(presentationTimeSamples)
        }

        let sampleRate = try sampleRateTimeScale(for: buffer.format.sampleRate)
        let formatDescription = try makeFormatDescription(for: buffer.format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: presentationTimeSamples, timescale: sampleRate),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard createStatus == noErr, let sampleBuffer else {
            throw PCMBufferToSampleBufferError.sampleBufferCreationFailed(createStatus)
        }

        let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            bufferList: buffer.audioBufferList
        )

        guard copyStatus == noErr else {
            throw PCMBufferToSampleBufferError.dataBufferCreationFailed(copyStatus)
        }

        return sampleBuffer
    }

    private func makeFormatDescription(for format: AVAudioFormat) throws -> CMAudioFormatDescription {
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDescription else {
            throw PCMBufferToSampleBufferError.audioFormatDescriptionCreationFailed(status)
        }

        return formatDescription
    }

    private func sampleRateTimeScale(for sampleRate: Double) throws -> CMTimeScale {
        let roundedSampleRate = sampleRate.rounded()
        guard sampleRate.isFinite,
              roundedSampleRate > 0,
              roundedSampleRate <= Double(CMTimeScale.max),
              abs(sampleRate - roundedSampleRate) < 0.000_001
        else {
            throw PCMBufferToSampleBufferError.invalidSampleRate(sampleRate)
        }

        return CMTimeScale(roundedSampleRate)
    }
}

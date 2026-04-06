import Foundation
import OSLog
@preconcurrency import AVFoundation

public enum MeetingAudioCaptureEvent: Sendable {
    case microphoneBuffer(AVAudioPCMBuffer, AVAudioTime)
    case systemBuffer(AVAudioPCMBuffer, AVAudioTime)
    case error(MeetingAudioError)
}

public protocol MeetingAudioCapturing: Sendable {
    var events: AsyncStream<MeetingAudioCaptureEvent> { get async }
    func start() async throws
    func stop() async
}

protocol MeetingMicrophoneCapturing: Sendable {
    typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    func start(handler: @escaping AudioBufferHandler) throws
    func stop()
}

extension MicrophoneCapture: MeetingMicrophoneCapturing {}

protocol MeetingSystemAudioTapping: Sendable {
    typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    func start(handler: @escaping AudioBufferHandler) throws
    func stop()
}

@available(macOS 14.2, *)
extension SystemAudioTap: MeetingSystemAudioTapping {}

public actor MeetingAudioCaptureService {
    public typealias EventHandler = @Sendable (MeetingAudioCaptureEvent) -> Void

    // A 48kHz system tap can deliver ~500 callbacks over 5 seconds if Core Audio
    // uses 480-frame buffers. The live transcription chunker needs that full span
    // to accumulate its first 80k resampled samples, so the capture queue must be
    // able to absorb at least one burst-sized chunk across both sources.
    private static let captureEventBufferCapacity = 2048

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
    private let microphoneCapture: any MeetingMicrophoneCapturing
    private let systemAudioTapFactory: @Sendable () throws -> any MeetingSystemAudioTapping

    private var systemAudioTap: (any MeetingSystemAudioTapping)?
    private var eventHandler: EventHandler?
    private var isCapturing = false

    private var eventContinuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var cachedEvents: AsyncStream<MeetingAudioCaptureEvent>?

    public init() {
        self.microphoneCapture = MicrophoneCapture()
        self.systemAudioTapFactory = {
            guard #available(macOS 14.2, *) else {
                throw MeetingAudioError.unsupportedPlatform
            }
            return SystemAudioTap()
        }
    }

    init(
        microphoneCapture: any MeetingMicrophoneCapturing,
        systemAudioTapFactory: @escaping @Sendable () throws -> any MeetingSystemAudioTapping
    ) {
        self.microphoneCapture = microphoneCapture
        self.systemAudioTapFactory = systemAudioTapFactory
    }

    public var events: AsyncStream<MeetingAudioCaptureEvent> {
        if let cachedEvents {
            return cachedEvents
        }

        var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
        let stream = AsyncStream<MeetingAudioCaptureEvent>(
            bufferingPolicy: .bufferingNewest(Self.captureEventBufferCapacity)
        ) {
            continuation = $0
        }
        eventContinuation = continuation
        cachedEvents = stream
        return stream
    }

    public func start() async throws {
        try await start { [weak self] event in
            Task { await self?.yieldEvent(event) }
        }
    }

    public func start(handler: @escaping EventHandler) async throws {
        guard !isCapturing else {
            throw MeetingAudioError.alreadyRunning
        }

        eventHandler = handler
        let tap = try systemAudioTapFactory()

        do {
            try microphoneCapture.start { [weak self] buffer, time in
                guard let copy = Self.deepCopyBuffer(buffer) else { return }
                Task { await self?.handle(.microphoneBuffer(copy, time)) }
            }

            try tap.start { [weak self] buffer, time in
                guard let copy = Self.deepCopyBuffer(buffer) else {
                    Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
                        .warning("deepCopyBuffer nil for system tap: format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)")
                    return
                }
                Task { await self?.handle(.systemBuffer(copy, time)) }
            }
        } catch {
            microphoneCapture.stop()
            tap.stop()
            finishEventStream()
            eventHandler = nil
            throw error
        }

        systemAudioTap = tap
        isCapturing = true
        logger.info("Meeting audio capture started")
    }

    public func stop() {
        guard isCapturing else { return }

        microphoneCapture.stop()
        systemAudioTap?.stop()
        systemAudioTap = nil
        isCapturing = false

        eventContinuation?.finish()
        finishEventStream()
        eventHandler = nil
        logger.info("Meeting audio capture stopped")
    }

    private func handle(_ event: MeetingAudioCaptureEvent) {
        eventHandler?(event)
    }

    private func yieldEvent(_ event: MeetingAudioCaptureEvent) {
        eventContinuation?.yield(event)
    }

    private func finishEventStream() {
        eventContinuation?.finish()
        eventContinuation = nil
        cachedEvents = nil
    }

    private static func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: buffer.format.commonFormat,
            sampleRate: buffer.format.sampleRate,
            channels: buffer.format.channelCount,
            interleaved: false
        ), let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)

        if buffer.format.isInterleaved {
            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            guard let sourceData = audioBuffer.mData else { return nil }

            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                guard let destination = copy.floatChannelData else { return nil }
                let source = sourceData.assumingMemoryBound(to: Float.self)
                for frameIndex in 0..<frameCount {
                    for channelIndex in 0..<channelCount {
                        destination[channelIndex][frameIndex] = source[(frameIndex * channelCount) + channelIndex]
                    }
                }
            case .pcmFormatInt16:
                guard let destination = copy.int16ChannelData else { return nil }
                let source = sourceData.assumingMemoryBound(to: Int16.self)
                for frameIndex in 0..<frameCount {
                    for channelIndex in 0..<channelCount {
                        destination[channelIndex][frameIndex] = source[(frameIndex * channelCount) + channelIndex]
                    }
                }
            case .pcmFormatInt32:
                guard let destination = copy.int32ChannelData else { return nil }
                let source = sourceData.assumingMemoryBound(to: Int32.self)
                for frameIndex in 0..<frameCount {
                    for channelIndex in 0..<channelCount {
                        destination[channelIndex][frameIndex] = source[(frameIndex * channelCount) + channelIndex]
                    }
                }
            default:
                return nil
            }
        } else if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel], count: frameCount)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel], count: frameCount)
            }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel], count: frameCount)
            }
        }

        return copy
    }
}

extension AVAudioPCMBuffer {
    public var rmsLevel: Float {
        if let channelData = floatChannelData, frameLength > 0 {
            let samples = channelData[0]
            var sum: Float = 0
            for index in 0..<Int(frameLength) {
                sum += samples[index] * samples[index]
            }
            return min(1.0, sqrt(sum / Float(frameLength)) * 10)
        }

        if let channelData = int16ChannelData, frameLength > 0 {
            let samples = channelData[0]
            var sum: Float = 0
            for index in 0..<Int(frameLength) {
                let normalized = Float(samples[index]) / Float(Int16.max)
                sum += normalized * normalized
            }
            return min(1.0, sqrt(sum / Float(frameLength)) * 10)
        }

        if let channelData = int32ChannelData, frameLength > 0 {
            let samples = channelData[0]
            var sum: Float = 0
            for index in 0..<Int(frameLength) {
                let normalized = Float(samples[index]) / Float(Int32.max)
                sum += normalized * normalized
            }
            return min(1.0, sqrt(sum / Float(frameLength)) * 10)
        }

        return 0
    }
}

extension MeetingAudioCaptureService: MeetingAudioCapturing {}

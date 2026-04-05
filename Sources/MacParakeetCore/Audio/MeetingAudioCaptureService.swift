import Foundation
import OSLog
@preconcurrency import AVFoundation

public enum MeetingAudioCaptureEvent: Sendable {
    case microphoneBuffer(AVAudioPCMBuffer, AVAudioTime)
    case systemBuffer(AVAudioPCMBuffer, AVAudioTime)
    case error(MeetingAudioError)
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

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
    private let microphoneCapture: any MeetingMicrophoneCapturing
    private let systemAudioTapFactory: @Sendable () -> any MeetingSystemAudioTapping

    private var systemAudioTap: (any MeetingSystemAudioTapping)?
    private var eventHandler: EventHandler?
    private var isCapturing = false

    private var eventContinuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var cachedEvents: AsyncStream<MeetingAudioCaptureEvent>?

    public init() {
        self.microphoneCapture = MicrophoneCapture()
        self.systemAudioTapFactory = {
            if #available(macOS 14.2, *) {
                return SystemAudioTap()
            }
            fatalError("System audio tap requires macOS 14.2+")
        }
    }

    init(
        microphoneCapture: any MeetingMicrophoneCapturing,
        systemAudioTapFactory: @escaping @Sendable () -> any MeetingSystemAudioTapping
    ) {
        self.microphoneCapture = microphoneCapture
        self.systemAudioTapFactory = systemAudioTapFactory
    }

    public var events: AsyncStream<MeetingAudioCaptureEvent> {
        if let cachedEvents {
            return cachedEvents
        }

        var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
        let stream = AsyncStream<MeetingAudioCaptureEvent>(bufferingPolicy: .bufferingNewest(32)) {
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
        let tap = systemAudioTapFactory()

        do {
            try microphoneCapture.start { [weak self] buffer, time in
                guard let copy = Self.deepCopyBuffer(buffer) else { return }
                Task { await self?.handle(.microphoneBuffer(copy, time)) }
            }

            try tap.start { [weak self] buffer, time in
                guard let copy = Self.deepCopyBuffer(buffer) else { return }
                Task { await self?.handle(.systemBuffer(copy, time)) }
            }
        } catch {
            microphoneCapture.stop()
            tap.stop()
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
        eventContinuation = nil
        cachedEvents = nil
        eventHandler = nil
        logger.info("Meeting audio capture stopped")
    }

    private func handle(_ event: MeetingAudioCaptureEvent) {
        eventHandler?(event)
    }

    private func yieldEvent(_ event: MeetingAudioCaptureEvent) {
        eventContinuation?.yield(event)
    }

    private static func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: buffer.format.commonFormat,
            sampleRate: buffer.format.sampleRate,
            channels: buffer.format.channelCount,
            interleaved: buffer.format.isInterleaved
        ), let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                dst[channel].update(from: src[channel], count: Int(buffer.frameLength))
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                dst[channel].update(from: src[channel], count: Int(buffer.frameLength))
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

        return 0
    }
}

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
    func start(sourceMode: MeetingAudioSourceMode?) async throws -> MeetingAudioCaptureStartReport
    func stop() async
}

public extension MeetingAudioCapturing {
    func start() async throws -> MeetingAudioCaptureStartReport {
        try await start(sourceMode: nil)
    }
}

protocol MeetingMicrophoneCapturing: Sendable {
    typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    typealias StallObserver = @Sendable (MeetingAudioError) -> Void
    func start(
        processingMode: MeetingMicProcessingMode,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) throws -> MeetingMicrophoneCaptureStartReport
    func stop()
}

extension MicrophoneCapture: MeetingMicrophoneCapturing {}

protocol MeetingSystemAudioTapping: Sendable {
    typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    typealias StallObserver = @Sendable (MeetingAudioError) -> Void
    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) throws
    func stop()
}

extension MeetingSystemAudioTapping {
    func start(handler: @escaping AudioBufferHandler) throws {
        try start(handler: handler, onStall: nil)
    }
}

@available(macOS 14.2, *)
extension SystemAudioTap: MeetingSystemAudioTapping {}

public actor MeetingAudioCaptureService {
    public typealias EventHandler = @Sendable (MeetingAudioCaptureEvent) -> Void
    typealias MeetingMicrophoneCaptureFactory = @Sendable () -> any MeetingMicrophoneCapturing

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
    private let microphoneCapture: any MeetingMicrophoneCapturing
    private let systemAudioTapFactory: @Sendable () throws -> any MeetingSystemAudioTapping
    private let micProcessingMode: MeetingMicProcessingMode
    private let sourceModeProvider: @Sendable () -> MeetingAudioSourceMode
    private let eventSink = EventSink()

    private var systemAudioTap: (any MeetingSystemAudioTapping)?
    private var isCapturing = false

    private var eventContinuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var cachedEvents: AsyncStream<MeetingAudioCaptureEvent>?

    public init(
        micProcessingMode: MeetingMicProcessingMode = .raw,
        selectedInputDeviceUIDProvider: @escaping @Sendable () -> String? = { nil },
        sourceModeProvider: @escaping @Sendable () -> MeetingAudioSourceMode = { .microphoneAndSystem }
    ) {
        self.microphoneCapture = MicrophoneCapture(
            selectedInputDeviceUIDProvider: selectedInputDeviceUIDProvider
        )
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
        self.systemAudioTapFactory = {
            guard #available(macOS 14.2, *) else {
                throw MeetingAudioError.unsupportedPlatform
            }
            return SystemAudioTap()
        }
    }

    init(
        microphoneCaptureFactory: @escaping MeetingMicrophoneCaptureFactory,
        systemAudioTapFactory: @escaping @Sendable () throws -> any MeetingSystemAudioTapping,
        micProcessingMode: MeetingMicProcessingMode = .raw,
        sourceModeProvider: @escaping @Sendable () -> MeetingAudioSourceMode = { .microphoneAndSystem }
    ) {
        self.microphoneCapture = microphoneCaptureFactory()
        self.systemAudioTapFactory = systemAudioTapFactory
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
    }

    init(
        microphoneCapture: any MeetingMicrophoneCapturing,
        systemAudioTapFactory: @escaping @Sendable () throws -> any MeetingSystemAudioTapping,
        micProcessingMode: MeetingMicProcessingMode = .raw,
        sourceModeProvider: @escaping @Sendable () -> MeetingAudioSourceMode = { .microphoneAndSystem }
    ) {
        self.microphoneCapture = microphoneCapture
        self.systemAudioTapFactory = systemAudioTapFactory
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
    }

    public var events: AsyncStream<MeetingAudioCaptureEvent> {
        if let cachedEvents {
            return cachedEvents
        }

        var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
        let stream = AsyncStream<MeetingAudioCaptureEvent>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        eventContinuation = continuation
        cachedEvents = stream
        return stream
    }

    public func start(sourceMode sourceModeOverride: MeetingAudioSourceMode? = nil) async throws -> MeetingAudioCaptureStartReport {
        _ = events
        let continuation = eventContinuation
        return try await start(sourceMode: sourceModeOverride) { event in
            continuation?.yield(event)
        }
    }

    public func start(
        sourceMode sourceModeOverride: MeetingAudioSourceMode? = nil,
        handler: @escaping EventHandler
    ) async throws -> MeetingAudioCaptureStartReport {
        guard !isCapturing else {
            throw MeetingAudioError.alreadyRunning
        }

        let tap = try systemAudioTapFactory()
        let sourceMode = sourceModeOverride ?? sourceModeProvider()
        eventSink.setHandler(handler)
        var microphoneStartReport: MeetingMicrophoneCaptureStartReport?
        var attemptedMicrophoneStart = false

        do {
            if sourceMode.capturesMicrophone {
                attemptedMicrophoneStart = true
                microphoneStartReport = try microphoneCapture.start(
                    processingMode: micProcessingMode,
                    handler: { [weak self] buffer, time in
                        guard let copy = Self.deepCopyBuffer(buffer) else {
                            Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
                                .warning("deepCopyBuffer nil for microphone capture: format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)")
                            self?.eventSink.emit(
                                .error(
                                    .captureRuntimeFailure(
                                        "microphone buffer copy failed (format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount))"
                                    )
                                )
                            )
                            return
                        }
                        self?.eventSink.emit(.microphoneBuffer(copy, time))
                    },
                    onStall: { [weak self] error in
                        self?.eventSink.emit(.error(error))
                    }
                )
            }

            try tap.start(
                handler: { [weak self] buffer, time in
                    guard let copy = Self.deepCopyBuffer(buffer) else {
                        Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
                            .warning("deepCopyBuffer nil for system tap: format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)")
                        self?.eventSink.emit(
                            .error(
                                .captureRuntimeFailure(
                                    "system buffer copy failed (format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount))"
                                )
                            )
                        )
                        return
                    }
                    self?.eventSink.emit(.systemBuffer(copy, time))
                },
                onStall: { [weak self] error in
                    self?.eventSink.emit(.error(error))
                }
            )
        } catch {
            if attemptedMicrophoneStart {
                microphoneCapture.stop()
            }
            tap.stop()
            finishEventStream()
            eventSink.setHandler(nil)
            throw error
        }

        systemAudioTap = tap
        isCapturing = true
        logger.info(
            "Meeting audio capture started source_mode=\(sourceMode.rawValue, privacy: .public) microphone_started=\(microphoneStartReport != nil, privacy: .public) requested_mic_mode=\(String(describing: microphoneStartReport?.requestedMode), privacy: .public) effective_mic_mode=\(microphoneStartReport?.effectiveMode.rawValue ?? "none", privacy: .public)"
        )
        return MeetingAudioCaptureStartReport(
            sourceMode: sourceMode,
            microphone: microphoneStartReport
        )
    }

    public func stop() {
        guard isCapturing else { return }

        microphoneCapture.stop()
        systemAudioTap?.stop()
        systemAudioTap = nil
        isCapturing = false

        eventContinuation?.finish()
        finishEventStream()
        eventSink.setHandler(nil)
        logger.info("Meeting audio capture stopped")
    }

    private func finishEventStream() {
        eventContinuation?.finish()
        eventContinuation = nil
        cachedEvents = nil
    }

    private static func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format: AVAudioFormat
        if buffer.format.isInterleaved {
            guard let nonInterleavedFormat = AVAudioFormat(
                commonFormat: buffer.format.commonFormat,
                sampleRate: buffer.format.sampleRate,
                channels: buffer.format.channelCount,
                interleaved: false
            ) else {
                return nil
            }
            format = nonInterleavedFormat
        } else {
            // Preserve channel layout details from Core Audio (for example VPIO
            // multichannel formats) instead of reconstructing from channel count.
            format = buffer.format
        }

        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
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

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: MeetingAudioCaptureService.EventHandler?

    func setHandler(_ handler: MeetingAudioCaptureService.EventHandler?) {
        lock.withLock {
            self.handler = handler
        }
    }

    func emit(_ event: MeetingAudioCaptureEvent) {
        let currentHandler = lock.withLock { handler }
        currentHandler?(event)
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

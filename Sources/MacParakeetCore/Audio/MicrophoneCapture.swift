import Foundation
import OSLog
@preconcurrency import AVFoundation

public final class MicrophoneCapture: @unchecked Sendable {
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopping
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MicrophoneCapture")
    private let lifecycleQueue = DispatchQueue(label: "com.macparakeet.microphonecapture")
    private let watchdogQueue = DispatchQueue(label: "com.macparakeet.microphonecapture.watchdog", qos: .utility)
    private let handlerLock = NSLock()
    private let selectedInputDeviceUIDProvider: @Sendable () -> String?
    private let audioEngine = AVAudioEngine()
    private let bufferSize: AVAudioFrameCount = 4096
    private let watchdogLock = NSLock()

    private var state: LifecycleState = .idle
    private var bufferHandler: AudioBufferHandler?
    private var firstBufferReceived = false
    private var watchdogWorkItem: DispatchWorkItem?

    public init(
        selectedInputDeviceUIDProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.selectedInputDeviceUIDProvider = selectedInputDeviceUIDProvider
    }

    deinit {
        stop()
    }

    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public var inputFormat: AVAudioFormat? {
        do {
            let format = try catchingObjCException {
                audioEngine.inputNode.outputFormat(forBus: 0)
            }
            return format.sampleRate > 0 ? format : nil
        } catch {
            logger.error("Failed to query microphone input format: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func start(
        processingMode: MeetingMicProcessingMode = .raw,
        handler: @escaping AudioBufferHandler
    ) throws -> MeetingMicrophoneCaptureStartReport {
        var startError: Error?
        var didStart = false
        var startReport = MeetingMicrophoneCaptureStartReport(
            requestedMode: processingMode,
            effectiveMode: .raw
        )

        lifecycleQueue.sync {
            guard state == .idle else {
                startError = MeetingAudioError.alreadyRunning
                return
            }

            guard Self.hasPermission else {
                startError = MeetingAudioError.microphonePermissionDenied
                return
            }

            let inputNode = audioEngine.inputNode
            applySelectedInputDeviceIfAvailable(on: audioEngine)
            state = .starting
            handlerLock.withLock { bufferHandler = handler }
            do {
                startReport = try installTapAndStartEngine(
                    inputNode: inputNode,
                    processingMode: processingMode
                )
                state = .running
                didStart = true
            } catch {
                handlerLock.withLock { bufferHandler = nil }
                state = .idle
                if let meetingError = error as? MeetingAudioError {
                    startError = meetingError
                } else {
                    startError = MeetingAudioError.audioEngineStartFailed(error.localizedDescription)
                }
            }
        }

        if let startError {
            throw startError
        }
        if didStart {
            let activeFormat = inputFormat
            logger.info(
                "microphone_capture_started requested_mode=\(String(describing: processingMode), privacy: .public) effective_mode=\(startReport.effectiveMode.rawValue, privacy: .public) sample_rate=\(activeFormat?.sampleRate ?? 0, privacy: .public) channels=\(activeFormat?.channelCount ?? 0, privacy: .public) interleaved=\(activeFormat?.isInterleaved ?? false, privacy: .public)"
            )
        }
        return startReport
    }

    public func stop() {
        var didStop = false

        lifecycleQueue.sync {
            guard state != .idle else { return }
            state = .stopping

            try? catchingObjCException {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            audioEngine.stop()
            handlerLock.withLock {
                bufferHandler = nil
            }
            resetDiagnosticsState()
            state = .idle
            didStop = true
        }

        if didStop {
            logger.info("microphone_capture_stopped")
        }
    }

    private func installTapAndStartEngine(
        inputNode: AVAudioInputNode,
        processingMode: MeetingMicProcessingMode
    ) throws -> MeetingMicrophoneCaptureStartReport {
        let format: AVAudioFormat
        do {
            format = try catchingObjCException {
                inputNode.outputFormat(forBus: 0)
            }
        } catch {
            throw MeetingAudioError.audioEngineStartFailed(
                "Failed to query microphone format: \(error.localizedDescription)"
            )
        }

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingAudioError.noMicrophoneAvailable
        }

        let effectiveMode = try configureInputProcessing(
            for: inputNode,
            requestedMode: processingMode
        )

        do {
            // Use `format: nil` so AVFAudio provides the bus's live format.
            // This avoids aggregate-device format drift crashes.
            try catchingObjCException {
                inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, time in
                    guard let self,
                          let callback = self.handlerLock.withLock({ self.bufferHandler }) else { return }
                    self.markFirstBufferReceived()
                    callback(buffer, time)
                }
            }
        } catch {
            throw MeetingAudioError.audioEngineStartFailed(
                "Failed to install microphone tap: \(error.localizedDescription)"
            )
        }

        do {
            scheduleSilentBufferWatchdog()
            try audioEngine.start()
        } catch {
            try? catchingObjCException {
                inputNode.removeTap(onBus: 0)
            }
            resetDiagnosticsState()
            throw MeetingAudioError.audioEngineStartFailed(error.localizedDescription)
        }

        return MeetingMicrophoneCaptureStartReport(
            requestedMode: processingMode,
            effectiveMode: effectiveMode
        )
    }

    private func configureInputProcessing(
        for inputNode: AVAudioInputNode,
        requestedMode: MeetingMicProcessingMode
    ) throws -> MeetingMicProcessingEffectiveMode {
        switch requestedMode {
        case .raw:
            do {
                try setVoiceProcessing(enabled: false, on: inputNode)
            } catch {
                logger.debug(
                    "meeting_mic_processing_raw_disable_failed reason=\(error.localizedDescription, privacy: .public)"
                )
            }
            return .raw
        case .vpioPreferred:
            do {
                try setVoiceProcessing(enabled: true, on: inputNode)
                logger.info("meeting_mic_processing mode=vpio requested=vpioPreferred effective=vpio")
                return .vpio
            } catch {
                logger.warning(
                    "meeting_mic_processing_fallback requested=vpioPreferred effective=raw reason=\(error.localizedDescription, privacy: .public)"
                )
                do {
                    try setVoiceProcessing(enabled: false, on: inputNode)
                } catch {
                    logger.debug(
                        "meeting_mic_processing_fallback_disable_failed reason=\(error.localizedDescription, privacy: .public)"
                    )
                }
                return .raw
            }
        case .vpioRequired:
            do {
                try setVoiceProcessing(enabled: true, on: inputNode)
                logger.info("meeting_mic_processing mode=vpio requested=vpioRequired effective=vpio")
                return .vpio
            } catch {
                throw MeetingAudioError.microphoneProcessingUnavailable(
                    mode: .vpioRequired,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func setVoiceProcessing(
        enabled: Bool,
        on inputNode: AVAudioInputNode
    ) throws {
        try catchingObjCException {
            try inputNode.setVoiceProcessingEnabled(enabled)
        }
    }

    private func applySelectedInputDeviceIfAvailable(on engine: AVAudioEngine) {
        guard let uid = AudioDeviceManager.normalizedUID(selectedInputDeviceUIDProvider()) else {
            guard let defaultID = AudioDeviceManager.defaultInputDevice() else {
                logger.warning("meeting_default_input_device_missing")
                return
            }
            guard AudioDeviceManager.setInputDevice(defaultID, on: engine) else {
                logger.warning(
                    "meeting_default_input_device_set_failed id=\(defaultID, privacy: .public)"
                )
                return
            }
            let name = AudioDeviceManager.deviceName(defaultID) ?? "unknown"
            logger.info(
                "meeting_default_input_device_applied id=\(defaultID, privacy: .public) name=\(name, privacy: .public)"
            )
            return
        }
        guard let deviceID = AudioDeviceManager.inputDeviceID(forUID: uid) else {
            logger.warning("meeting_selected_input_device_missing uid=\(uid, privacy: .private)")
            return
        }
        guard AudioDeviceManager.setInputDevice(deviceID, on: engine) else {
            logger.warning(
                "meeting_selected_input_device_set_failed uid=\(uid, privacy: .private) id=\(deviceID, privacy: .public)"
            )
            return
        }
        let name = AudioDeviceManager.deviceName(deviceID) ?? "unknown"
        logger.info(
            "meeting_selected_input_device_applied uid=\(uid, privacy: .private) id=\(deviceID, privacy: .public) name=\(name, privacy: .public)"
        )
    }

    private func scheduleSilentBufferWatchdog() {
        let workItem = watchdogLock.withLock { () -> DispatchWorkItem in
            firstBufferReceived = false
            watchdogWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldLog = self.watchdogLock.withLock { !self.firstBufferReceived }
                guard shouldLog else { return }
                self.logger.warning("microphone_capture_no_buffers_within_timeout")
            }
            watchdogWorkItem = item
            return item
        }
        watchdogQueue.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func markFirstBufferReceived() {
        let shouldLog = watchdogLock.withLock {
            guard !firstBufferReceived else { return false }
            firstBufferReceived = true
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
            return true
        }
        if shouldLog {
            logger.info("microphone_capture_first_buffer_received")
        }
    }

    private func resetDiagnosticsState() {
        watchdogLock.withLock {
            firstBufferReceived = false
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
        }
    }
}

import AudioToolbox
import CoreAudio
import Foundation
import OSLog
@preconcurrency import AVFoundation

@available(macOS 14.2, *)
public final class SystemAudioTap: @unchecked Sendable {
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopping
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "SystemAudioTap")
    private let queue = DispatchQueue(label: "com.macparakeet.systemaudiotap", qos: .userInitiated)

    private var tapID: AudioObjectID = .meetingUnknown
    private var aggregateDeviceID: AudioObjectID = .meetingUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapStreamDescription: AudioStreamBasicDescription?
    private var tapUUIDString: String?

    private var state: LifecycleState = .idle
    private var bufferHandler: AudioBufferHandler?

    public init() {}

    deinit {
        stop()
    }

    public func start(handler: @escaping AudioBufferHandler) throws {
        var startError: Error?
        var didStart = false

        queue.sync {
            guard state == .idle else {
                startError = MeetingAudioError.alreadyRunning
                return
            }

            state = .starting
            bufferHandler = handler

            do {
                try createProcessTap()
                try createAggregateDevice()
                try startDeviceIO()
                state = .running
                didStart = true
            } catch {
                tearDownResources(clearHandler: true)
                startError = error
            }
        }

        if let startError {
            throw startError
        }
        if didStart {
            logger.info("System audio tap started")
        }
    }

    public func stop() {
        var didStop = false
        queue.sync {
            guard state != .idle || aggregateDeviceID.isMeetingValid || tapID.isMeetingValid else { return }
            state = .stopping
            tearDownResources(clearHandler: true)
            didStop = true
        }
        if didStop {
            logger.info("System audio tap stopped")
        }
    }

    private func tearDownResources(clearHandler: Bool) {
        if aggregateDeviceID.isMeetingValid, let procID = deviceProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }

        if aggregateDeviceID.isMeetingValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .meetingUnknown
        }

        if tapID.isMeetingValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .meetingUnknown
        }

        if clearHandler {
            bufferHandler = nil
        }
        state = .idle
        tapUUIDString = nil
    }

    private func createProcessTap() throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        let tapUUID = UUID()
        tapDescription.uuid = tapUUID
        tapDescription.muteBehavior = .unmuted
        tapUUIDString = tapUUID.uuidString

        var newTapID: AudioObjectID = .meetingUnknown
        let status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)

        guard status == noErr else {
            throw MeetingAudioError.tapCreationFailed(status)
        }

        tapID = newTapID
        tapStreamDescription = try newTapID.readMeetingTapStreamDescription()
    }

    private func createAggregateDevice() throws {
        guard let tapUUIDString else {
            throw MeetingAudioError.invalidTapFormat
        }

        let systemOutputID = try AudioObjectID.readMeetingDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readMeetingDeviceUID()
        let aggregateUID = "com.macparakeet.aggregate.\(UUID().uuidString)"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacParakeet Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUIDString,
                ]
            ]
        ]

        var newDeviceID: AudioObjectID = .meetingUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)

        guard status == noErr else {
            throw MeetingAudioError.aggregateDeviceCreationFailed(status)
        }

        aggregateDeviceID = newDeviceID
    }

    private func startDeviceIO() throws {
        guard var streamDesc = tapStreamDescription,
              let format = AVAudioFormat(streamDescription: &streamDesc) else {
            throw MeetingAudioError.invalidTapFormat
        }

        let ioBlock: AudioDeviceIOBlock = { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self,
                  let callback = self.bufferHandler,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: inInputData,
                    deallocator: nil
                  ) else {
                return
            }

            let time = AVAudioTime(hostTime: inInputTime.pointee.mHostTime)
            callback(buffer, time)
        }

        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue, ioBlock)

        guard status == noErr else {
            throw MeetingAudioError.aggregateDeviceCreationFailed(status)
        }

        deviceProcID = procID
        status = AudioDeviceStart(aggregateDeviceID, procID)

        guard status == noErr else {
            throw MeetingAudioError.aggregateDeviceCreationFailed(status)
        }
    }
}

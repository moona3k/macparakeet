import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Provides CoreAudio device enumeration and selection for audio input.
///
/// Used by ``AudioRecorder`` to detect and fall back from broken input devices
/// (e.g., Bluetooth headphones that report invalid formats).
public enum AudioDeviceManager {

    private static let logger = Logger(
        subsystem: "com.macparakeet.core", category: "AudioDeviceManager"
    )

    /// Describes an available audio input device.
    public struct InputDevice: Sendable, CustomStringConvertible {
        public let id: AudioDeviceID
        public let uid: String
        public let name: String
        public let transportType: UInt32

        public init(
            id: AudioDeviceID,
            uid: String,
            name: String,
            transportType: UInt32
        ) {
            self.id = id
            self.uid = uid
            self.name = name
            self.transportType = transportType
        }

        public var isBuiltIn: Bool {
            transportType == kAudioDeviceTransportTypeBuiltIn
        }

        public var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        public var transportLabel: String {
            Self.label(for: transportType)
        }

        public var description: String {
            "\(name) (id=\(id), uid=\(uid), transport=\(transportLabel))"
        }

        static func label(for transport: UInt32) -> String {
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: return "built-in"
            case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
            case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
            case kAudioDeviceTransportTypeUSB: return "usb"
            case kAudioDeviceTransportTypeAggregate: return "aggregate"
            case kAudioDeviceTransportTypeVirtual: return "virtual"
            default: return "unknown(\(transport))"
            }
        }
    }

    // MARK: - Device Enumeration

    /// Returns all audio devices that have at least one input channel.
    public static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id in
            guard hasInputChannels(id) else { return nil }
            let name = deviceName(id) ?? "Unknown Device"
            guard let uid = deviceUID(id) else {
                logger.debug(
                    "skipping_input_device_without_uid id=\(id, privacy: .public) name=\(name, privacy: .public)"
                )
                return nil
            }
            let transport = transportType(id)
            return InputDevice(id: id, uid: uid, name: name, transportType: transport)
        }
    }

    /// Normalizes persisted CoreAudio device UIDs, treating nil and whitespace as absent.
    public static func normalizedUID(_ uid: String?) -> String? {
        let trimmed = uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the AudioDeviceID of the built-in microphone, if available.
    public static func builtInMicrophone() -> AudioDeviceID? {
        inputDevices().first(where: \.isBuiltIn)?.id
    }

    /// Returns the current system default input device ID.
    public static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Returns the current system default input device, if it can be resolved
    /// to a valid input device descriptor.
    public static func defaultInputDeviceInfo() -> InputDevice? {
        guard let id = defaultInputDevice() else { return nil }
        return deviceInfo(id)
    }

    /// Resolves a persistent CoreAudio device UID to the current process-local
    /// `AudioDeviceID`. Device IDs are not stable across boots or hardware
    /// topology changes, so app preferences should store UIDs and resolve late.
    public static func inputDeviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    // MARK: - Device Control

    /// Sets a specific input device on an AVAudioEngine's input audio unit.
    ///
    /// Must be called **after** accessing `engine.inputNode` (which creates the audio unit)
    /// and **before** reading `inputNode.outputFormat(forBus:)` or installing a tap.
    @discardableResult
    public static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else {
            logger.error("set_input_device failed: no audio unit on input node")
            return false
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            logger.error(
                "set_input_device failed: device_id=\(deviceID) OSStatus=\(status)"
            )
            return false
        }
        return true
    }

    /// Returns the AudioDeviceID currently assigned to an engine's input node.
    public static func currentInputDevice(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let audioUnit = engine.inputNode.audioUnit else { return nil }
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr else { return nil }
        return deviceID
    }

    // MARK: - Device Info

    /// Returns the name of a device.
    public static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // kAudioObjectPropertyName returns a retained CFString.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let validName = name else { return nil }
        return validName.takeRetainedValue() as String
    }

    /// Returns the persistent CoreAudio UID for a device.
    public static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let validUID = uid else { return nil }
        return validUID.takeRetainedValue() as String
    }

    /// Returns the transport type of a device (built-in, bluetooth, USB, etc.).
    public static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return 0 }
        return transport
    }

    /// Returns an InputDevice descriptor for a given device ID, or nil if not a valid input device.
    public static func deviceInfo(_ deviceID: AudioDeviceID) -> InputDevice? {
        guard hasInputChannels(deviceID) else { return nil }
        guard let uid = deviceUID(deviceID) else { return nil }
        let name = deviceName(deviceID) ?? "Unknown Device"
        let transport = transportType(deviceID)
        return InputDevice(id: deviceID, uid: uid, name: name, transportType: transport)
    }

    /// For aggregate devices, resolves the transport type of the first active sub-device.
    /// Returns nil if the device is not aggregate or has no sub-devices.
    public static func subDeviceTransport(_ deviceID: AudioDeviceID) -> UInt32? {
        // Only applies to aggregate devices
        guard transportType(deviceID) == kAudioDeviceTransportTypeAggregate else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var subDeviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &subDeviceIDs)
        guard status == noErr, let firstID = subDeviceIDs.first else { return nil }

        let subTransport = transportType(firstID)
        guard subTransport != 0 else { return nil }
        return subTransport
    }

    // MARK: - Private

    /// Checks whether a device has input channels (is a microphone/input device).
    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return false }

        // AudioBufferList is variable-length; allocate the full size reported by CoreAudio.
        let byteCount = max(Int(size), MemoryLayout<AudioBufferList>.size)
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let status2 = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer)
        guard status2 == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.contains { $0.mNumberChannels > 0 }
    }
}

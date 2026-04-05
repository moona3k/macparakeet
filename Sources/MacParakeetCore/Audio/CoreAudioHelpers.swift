import AudioToolbox
import CoreAudio
import Foundation

extension AudioObjectID {
    static let meetingSystemObject = AudioObjectID(kAudioObjectSystemObject)
    static let meetingUnknown = kAudioObjectUnknown

    var isMeetingValid: Bool { self != .meetingUnknown }
}

extension AudioObjectID {
    static func readMeetingDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = .meetingUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID.meetingSystemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr else {
            throw MeetingAudioError.aggregateDeviceCreationFailed(status)
        }

        return deviceID
    }

    func readMeetingDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }

        guard status == noErr else {
            throw MeetingAudioError.aggregateDeviceCreationFailed(status)
        }

        return uid as String
    }

    func readMeetingTapStreamDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            self,
            &address,
            0,
            nil,
            &size,
            &streamDescription
        )

        guard status == noErr else {
            throw MeetingAudioError.invalidTapFormat
        }

        return streamDescription
    }
}

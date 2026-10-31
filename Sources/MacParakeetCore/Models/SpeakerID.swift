import Foundation

public enum SpeakerID {
    public static func systemSpeaker(_ stableID: String) -> String {
        "\(AudioSource.system.rawValue):\(stableID)"
    }

    public static func source(for speakerID: String?) -> AudioSource? {
        switch speakerID {
        case AudioSource.microphone.rawValue:
            return .microphone
        case AudioSource.system.rawValue:
            return .system
        case let value? where value.hasPrefix("\(AudioSource.system.rawValue):"):
            return .system
        default:
            return nil
        }
    }

    public static func isSourceOnly(_ speakerID: String?) -> Bool {
        speakerID == AudioSource.microphone.rawValue || speakerID == AudioSource.system.rawValue
    }
}

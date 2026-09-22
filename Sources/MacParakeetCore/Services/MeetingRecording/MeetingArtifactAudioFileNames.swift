import Foundation

public enum MeetingArtifactAudioFileNames {
    public static let rawMicrophone = "microphone-raw.m4a"
    public static let cleanedMicrophone = "microphone-cleaned.m4a"
    public static let rawSystem = "system-raw.m4a"
    public static let playback = "meeting-playback.m4a"

    static let legacyRawMicrophone = "microphone.m4a"
    static let legacyRawSystem = "system.m4a"
    static let legacyPlayback = "meeting.m4a"

    static let managedCurrent: Set<String> = [
        playback,
        rawMicrophone,
        rawSystem,
        cleanedMicrophone,
    ]

    static let managedReadCompatible: Set<String> = managedCurrent.union([
        legacyPlayback,
        legacyRawMicrophone,
        legacyRawSystem,
    ])

    static func resolveRawMicrophoneURL(
        in folderURL: URL,
        fileManager: FileManager = .default
    ) -> (url: URL, exists: Bool) {
        resolveCurrentOrLegacyURL(
            in: folderURL,
            currentFileName: rawMicrophone,
            legacyFileName: legacyRawMicrophone,
            fileManager: fileManager)
    }

    static func resolveRawSystemURL(
        in folderURL: URL,
        fileManager: FileManager = .default
    ) -> (url: URL, exists: Bool) {
        resolveCurrentOrLegacyURL(
            in: folderURL,
            currentFileName: rawSystem,
            legacyFileName: legacyRawSystem,
            fileManager: fileManager)
    }

    static func resolvePlaybackURL(
        in folderURL: URL,
        fileManager: FileManager = .default
    ) -> (url: URL, exists: Bool) {
        resolveCurrentOrLegacyURL(
            in: folderURL,
            currentFileName: playback,
            legacyFileName: legacyPlayback,
            fileManager: fileManager)
    }

    static func rawMicrophoneURL(in folderURL: URL, fileManager: FileManager = .default) -> URL {
        resolveRawMicrophoneURL(in: folderURL, fileManager: fileManager).url
    }

    static func rawSystemURL(in folderURL: URL, fileManager: FileManager = .default) -> URL {
        resolveRawSystemURL(in: folderURL, fileManager: fileManager).url
    }

    static func playbackURL(in folderURL: URL, fileManager: FileManager = .default) -> URL {
        resolvePlaybackURL(in: folderURL, fileManager: fileManager).url
    }

    static func playbackCandidates(in folderURL: URL) -> [URL] {
        [
            folderURL.appendingPathComponent(playback),
            folderURL.appendingPathComponent(legacyPlayback),
        ]
    }

    private static func resolveCurrentOrLegacyURL(
        in folderURL: URL,
        currentFileName: String,
        legacyFileName: String,
        fileManager: FileManager
    ) -> (url: URL, exists: Bool) {
        let currentURL = folderURL.appendingPathComponent(currentFileName)
        if fileManager.fileExists(atPath: currentURL.path) {
            return (currentURL, true)
        }
        let legacyURL = folderURL.appendingPathComponent(legacyFileName)
        if fileManager.fileExists(atPath: legacyURL.path) {
            return (legacyURL, true)
        }
        return (currentURL, false)
    }
}

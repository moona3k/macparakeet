import Foundation

public enum MeetingArtifactAudioFileNames {
    public static let rawMicrophone = "microphone-raw.m4a"
    public static let cleanedMicrophone = "microphone-cleaned.m4a"
    public static let rawSystem = "system-raw.m4a"
    public static let playback = "meeting-playback.m4a"

    static let managedCurrent: Set<String> = [
        playback,
        rawMicrophone,
        rawSystem,
        cleanedMicrophone,
    ]

    // Deletion-only tolerance for first-pass pre-hardening dev artifacts. Do
    // not use these names for reads, recovery, loading, manifests, or writes.
    static let legacyDeletionOnly: Set<String> = [
        "meeting.m4a",
        "microphone.m4a",
        "system.m4a",
    ]
}

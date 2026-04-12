import Foundation

public struct MeetingRecordingOutput: Sendable, Equatable {
    public let sessionID: UUID
    public let displayName: String
    public let folderURL: URL
    public let mixedAudioURL: URL
    public let microphoneAudioURL: URL
    public let systemAudioURL: URL
    public let durationSeconds: TimeInterval
    public let sourceAlignment: MeetingSourceAlignment

    public init(
        sessionID: UUID,
        displayName: String,
        folderURL: URL,
        mixedAudioURL: URL,
        microphoneAudioURL: URL,
        systemAudioURL: URL,
        durationSeconds: TimeInterval,
        sourceAlignment: MeetingSourceAlignment
    ) {
        self.sessionID = sessionID
        self.displayName = displayName
        self.folderURL = folderURL
        self.mixedAudioURL = mixedAudioURL
        self.microphoneAudioURL = microphoneAudioURL
        self.systemAudioURL = systemAudioURL
        self.durationSeconds = durationSeconds
        self.sourceAlignment = sourceAlignment
    }

    public static func loadArchived(
        displayName: String,
        mixedAudioURL: URL,
        durationSeconds: TimeInterval
    ) throws -> MeetingRecordingOutput {
        let folderURL = mixedAudioURL.deletingLastPathComponent()
        let metadata = try MeetingRecordingMetadataStore.load(from: folderURL)
        let microphoneAudioURL = folderURL.appendingPathComponent("microphone.m4a")
        let systemAudioURL = folderURL.appendingPathComponent("system.m4a")

        if metadata.sourceAlignment.microphone != nil,
           !FileManager.default.fileExists(atPath: microphoneAudioURL.path) {
            throw MeetingAudioError.storageFailed("Missing archived meeting source file: microphone.m4a")
        }

        if metadata.sourceAlignment.system != nil,
           !FileManager.default.fileExists(atPath: systemAudioURL.path) {
            throw MeetingAudioError.storageFailed("Missing archived meeting source file: system.m4a")
        }

        return MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: displayName,
            folderURL: folderURL,
            mixedAudioURL: mixedAudioURL,
            microphoneAudioURL: microphoneAudioURL,
            systemAudioURL: systemAudioURL,
            durationSeconds: durationSeconds,
            sourceAlignment: metadata.sourceAlignment
        )
    }
}

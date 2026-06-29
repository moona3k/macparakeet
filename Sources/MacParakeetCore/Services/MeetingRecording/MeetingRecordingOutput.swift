import AVFoundation
import Foundation

public struct MeetingRecordingOutput: Sendable, Equatable {
    public let sessionID: UUID
    public let displayName: String
    public let folderURL: URL
    public let mixedAudioURL: URL
    public let microphoneAudioURL: URL
    public let systemAudioURL: URL
    /// Echo-cancelled microphone derived from the raw mic + system reference
    /// after stop (plan #605 U3). `nil` for single-source meetings or when no
    /// AEC assets are bundled. The raw `microphoneAudioURL` always stays the
    /// source of truth; this is a derived artifact preferred for the local
    /// ("Me") transcript via `microphoneTranscriptionURL(fileManager:)`.
    public let cleanedMicrophoneAudioURL: URL?
    public let durationSeconds: TimeInterval
    public let sourceAlignment: MeetingSourceAlignment
    public let speechEngine: SpeechEngineSelection
    public let speechEngineWasCaptured: Bool
    /// Free-form notes the user typed during the meeting, captured at finalize
    /// time. Threaded through to `Transcription.userNotes` by the caller so
    /// post-meeting summary generation can steer on what the user emphasized
    /// (ADR-020). `nil` when the user took no notes.
    public let userNotes: String?

    public init(
        sessionID: UUID,
        displayName: String,
        folderURL: URL,
        mixedAudioURL: URL,
        microphoneAudioURL: URL,
        systemAudioURL: URL,
        cleanedMicrophoneAudioURL: URL? = nil,
        durationSeconds: TimeInterval,
        sourceAlignment: MeetingSourceAlignment,
        speechEngine: SpeechEngineSelection = SpeechEngineSelection(engine: .parakeet),
        speechEngineWasCaptured: Bool = true,
        userNotes: String? = nil
    ) {
        self.sessionID = sessionID
        self.displayName = displayName
        self.folderURL = folderURL
        self.mixedAudioURL = mixedAudioURL
        self.microphoneAudioURL = microphoneAudioURL
        self.systemAudioURL = systemAudioURL
        self.cleanedMicrophoneAudioURL = cleanedMicrophoneAudioURL
        self.durationSeconds = durationSeconds
        self.sourceAlignment = sourceAlignment
        self.speechEngine = speechEngine
        self.speechEngineWasCaptured = speechEngineWasCaptured
        self.userNotes = userNotes
    }

    /// The microphone audio to transcribe for the local ("Me") track: the
    /// echo-cancelled artifact when it was derived and is non-empty, otherwise
    /// the raw mic. This public helper is intentionally cheap for UI/list paths;
    /// STT routing uses `validatedMicrophoneTranscriptionURL(fileManager:)`.
    /// Performs synchronous filesystem stat calls, so avoid hot main-actor loops.
    public func microphoneTranscriptionURL(fileManager: FileManager = .default) -> URL {
        if let cleanedMicrophoneAudioURL,
           Self.hasNonEmptyFile(at: cleanedMicrophoneAudioURL, fileManager: fileManager) {
            return cleanedMicrophoneAudioURL
        }
        return microphoneAudioURL
    }

    /// The microphone audio to transcribe for the local ("Me") STT track. This
    /// performs a synchronous decodability probe and should be called from
    /// background/actor transcription paths, not UI list population.
    func validatedMicrophoneTranscriptionURL(fileManager: FileManager = .default) -> URL {
        if let cleanedMicrophoneAudioURL,
           Self.isViableCleanedMicrophoneFile(at: cleanedMicrophoneAudioURL, fileManager: fileManager) {
            return cleanedMicrophoneAudioURL
        }
        return microphoneAudioURL
    }

    private static func isViableCleanedMicrophoneFile(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard hasNonEmptyFile(at: url, fileManager: fileManager),
              let file = try? AVAudioFile(forReading: url) else {
            return false
        }
        return file.length > 0
    }

    public static func loadArchived(
        displayName: String,
        mixedAudioURL: URL,
        durationSeconds: TimeInterval,
        fileManager: FileManager = .default
    ) throws -> MeetingRecordingOutput {
        let folderURL = mixedAudioURL.deletingLastPathComponent()
        let metadata = try MeetingRecordingMetadataStore.load(from: folderURL)
        let microphoneAudioURL = folderURL.appendingPathComponent("microphone.m4a")
        let systemAudioURL = folderURL.appendingPathComponent("system.m4a")
        let cleanedURL = folderURL.appendingPathComponent(
            MeetingCleanedMicRenderer.cleanedMicrophoneFileName)
        // Keep archive loading cheap; this is called from UI list/reopen paths.
        // The decodability probe stays in `validatedMicrophoneTranscriptionURL`,
        // which is the actual STT routing gate and falls back to raw if the
        // artifact is corrupt or partial.
        let cleanedMicrophoneAudioURL = hasNonEmptyFile(at: cleanedURL, fileManager: fileManager)
            ? cleanedURL
            : nil

        if metadata.sourceAlignment.microphone != nil,
           !hasFile(at: microphoneAudioURL, fileManager: fileManager) {
            throw MeetingAudioError.storageFailed("Missing archived meeting source file: microphone.m4a")
        }

        if metadata.sourceAlignment.system != nil,
           !hasFile(at: systemAudioURL, fileManager: fileManager) {
            throw MeetingAudioError.storageFailed("Missing archived meeting source file: system.m4a")
        }

        return MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: displayName,
            folderURL: folderURL,
            mixedAudioURL: mixedAudioURL,
            microphoneAudioURL: microphoneAudioURL,
            systemAudioURL: systemAudioURL,
            cleanedMicrophoneAudioURL: cleanedMicrophoneAudioURL,
            durationSeconds: durationSeconds,
            sourceAlignment: metadata.sourceAlignment,
            speechEngine: metadata.speechEngine,
            speechEngineWasCaptured: metadata.speechEngineWasCaptured
        )
    }

    private static func hasNonEmptyFile(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard hasFile(at: url, fileManager: fileManager),
              let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private static func hasFile(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}

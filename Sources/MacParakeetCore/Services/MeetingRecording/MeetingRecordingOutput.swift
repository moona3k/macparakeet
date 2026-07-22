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
    /// after stop (plan #605 U3). For dual-source meetings this may be the
    /// scheduled output path before the background render has completed. The raw
    /// `microphoneAudioURL` always stays the source of truth; STT finalization
    /// waits on `cleanedMicrophoneReadiness` before preferring this artifact.
    public let cleanedMicrophoneAudioURL: URL?
    let cleanedMicrophoneReadiness: MeetingCleanedMicrophoneReadiness?
    /// Probed duration of the canonical playback artifact, not wall-clock
    /// meeting time. `captureReport` independently preserves source-timeline
    /// truth, including sources that may be unavailable during crash recovery.
    public let durationSeconds: TimeInterval
    public let sourceAlignment: MeetingSourceAlignment
    /// Durable capture quality and elapsed-vs-playable duration truth. `nil`
    /// only for legacy meeting artifacts created before this report existed.
    public let captureReport: MeetingCaptureReport?
    public let speechEngine: SpeechEngineSelection
    public let speechEngineWasCaptured: Bool
    public let previewSpeechEngine: SpeechEngineSelection?
    public let startContext: MeetingStartContext?
    /// Free-form notes the user typed during the meeting, captured at finalize
    /// time. Threaded through to `Transcription.userNotes` by the caller so
    /// post-meeting summary generation can steer on what the user emphasized
    /// (ADR-020). `nil` when the user took no notes.
    public let userNotes: String?
    /// Local calendar context captured when the recording started.
    public let calendarEventSnapshot: MeetingCalendarSnapshot?

    /// Canonical duration persisted for playback and transcription rows.
    public var playableDurationMs: Int {
        max(0, Int((durationSeconds * 1_000).rounded()))
    }

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
        captureReport: MeetingCaptureReport? = nil,
        speechEngine: SpeechEngineSelection = SpeechEngineSelection(engine: .parakeet),
        speechEngineWasCaptured: Bool = true,
        previewSpeechEngine: SpeechEngineSelection? = nil,
        startContext: MeetingStartContext? = nil,
        userNotes: String? = nil,
        calendarEventSnapshot: MeetingCalendarSnapshot? = nil
    ) {
        self.init(
            sessionID: sessionID,
            displayName: displayName,
            folderURL: folderURL,
            mixedAudioURL: mixedAudioURL,
            microphoneAudioURL: microphoneAudioURL,
            systemAudioURL: systemAudioURL,
            cleanedMicrophoneAudioURL: cleanedMicrophoneAudioURL,
            cleanedMicrophoneReadiness: nil,
            durationSeconds: durationSeconds,
            sourceAlignment: sourceAlignment,
            captureReport: captureReport,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            previewSpeechEngine: previewSpeechEngine,
            startContext: startContext,
            userNotes: userNotes,
            calendarEventSnapshot: calendarEventSnapshot
        )
    }

    init(
        sessionID: UUID,
        displayName: String,
        folderURL: URL,
        mixedAudioURL: URL,
        microphoneAudioURL: URL,
        systemAudioURL: URL,
        cleanedMicrophoneAudioURL: URL? = nil,
        cleanedMicrophoneReadiness: MeetingCleanedMicrophoneReadiness?,
        durationSeconds: TimeInterval,
        sourceAlignment: MeetingSourceAlignment,
        captureReport: MeetingCaptureReport? = nil,
        speechEngine: SpeechEngineSelection = SpeechEngineSelection(engine: .parakeet),
        speechEngineWasCaptured: Bool = true,
        previewSpeechEngine: SpeechEngineSelection? = nil,
        startContext: MeetingStartContext? = nil,
        userNotes: String? = nil,
        calendarEventSnapshot: MeetingCalendarSnapshot? = nil
    ) {
        self.sessionID = sessionID
        self.displayName = displayName
        self.folderURL = folderURL
        self.mixedAudioURL = mixedAudioURL
        self.microphoneAudioURL = microphoneAudioURL
        self.systemAudioURL = systemAudioURL
        self.cleanedMicrophoneAudioURL = cleanedMicrophoneAudioURL
        self.cleanedMicrophoneReadiness = cleanedMicrophoneReadiness
        self.durationSeconds = durationSeconds
        self.sourceAlignment = sourceAlignment
        self.captureReport = captureReport
        self.speechEngine = speechEngine
        self.speechEngineWasCaptured = speechEngineWasCaptured
        self.previewSpeechEngine = previewSpeechEngine
        self.startContext = startContext
        self.userNotes = userNotes
        self.calendarEventSnapshot = calendarEventSnapshot
    }

    /// The microphone audio to transcribe for the local ("Me") track: the
    /// echo-cancelled artifact when it was derived and is non-empty, otherwise
    /// the raw mic. This public helper is intentionally cheap for UI/list paths;
    /// STT routing uses `validatedMicrophoneTranscriptionURL(fileManager:)`.
    /// Performs synchronous filesystem stat calls, so avoid hot main-actor loops.
    public func microphoneTranscriptionURL(fileManager: FileManager = .default) -> URL {
        if let cleanedMicrophoneAudioURL,
            Self.hasNonEmptyFile(at: cleanedMicrophoneAudioURL, fileManager: fileManager)
        {
            return cleanedMicrophoneAudioURL
        }
        return microphoneAudioURL
    }

    /// The microphone audio to transcribe for the local ("Me") STT track. This
    /// performs a synchronous decodability probe and should be called from
    /// background/actor transcription paths, not UI list population.
    func validatedMicrophoneTranscriptionURL(fileManager: FileManager = .default) -> URL {
        if let cleanedMicrophoneAudioURL,
            Self.isViableCleanedMicrophoneFile(at: cleanedMicrophoneAudioURL, fileManager: fileManager)
        {
            return cleanedMicrophoneAudioURL
        }
        return microphoneAudioURL
    }

    static func isViableCleanedMicrophoneFile(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard hasNonEmptyFile(at: url, fileManager: fileManager),
            let file = try? AVAudioFile(forReading: url)
        else {
            return false
        }
        return file.length > 0
    }

    /// Reconstructs an archived meeting from its canonical folder. The supplied
    /// duration is legacy fallback data; decodable playback media is authoritative.
    public static func loadArchived(
        displayName: String,
        mixedAudioURL: URL,
        durationSeconds: TimeInterval,
        fileManager: FileManager = .default
    ) throws -> MeetingRecordingOutput {
        let folderURL = mixedAudioURL.deletingLastPathComponent()
        let metadata = try MeetingRecordingMetadataStore.load(
            from: folderURL,
            fileManager: fileManager)
        let playbackAudio = MeetingArtifactAudioFileNames.resolvePlaybackURL(
            in: folderURL,
            fileManager: fileManager)
        let playbackDurationSeconds =
            probedDurationSeconds(
                at: playbackAudio.url,
                fileManager: fileManager
            ) ?? durationSeconds
        let microphoneAudio = MeetingArtifactAudioFileNames.resolveRawMicrophoneURL(
            in: folderURL,
            fileManager: fileManager)
        let systemAudio = MeetingArtifactAudioFileNames.resolveRawSystemURL(
            in: folderURL,
            fileManager: fileManager)
        let cleanedURL = folderURL.appendingPathComponent(
            MeetingCleanedMicRenderer.cleanedMicrophoneFileName)
        // Keep archive loading cheap; this is called from UI list/reopen paths.
        // The decodability probe stays in `validatedMicrophoneTranscriptionURL`,
        // which is the actual STT routing gate and falls back to raw if the
        // artifact is corrupt or partial.
        let cleanedMicrophoneAudioURL =
            hasNonEmptyFile(at: cleanedURL, fileManager: fileManager)
            ? cleanedURL
            : nil

        if metadata.sourceAlignment.microphone != nil,
            !microphoneAudio.exists
        {
            throw MeetingAudioError.storageFailed(
                "Missing archived meeting source file: \(MeetingArtifactAudioFileNames.rawMicrophone)"
                    + " or \(MeetingArtifactAudioFileNames.legacyRawMicrophone)")
        }

        if metadata.sourceAlignment.system != nil,
            !systemAudio.exists
        {
            throw MeetingAudioError.storageFailed(
                "Missing archived meeting source file: \(MeetingArtifactAudioFileNames.rawSystem)"
                    + " or \(MeetingArtifactAudioFileNames.legacyRawSystem)")
        }

        return MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: displayName,
            folderURL: folderURL,
            mixedAudioURL: playbackAudio.url,
            microphoneAudioURL: microphoneAudio.url,
            systemAudioURL: systemAudio.url,
            cleanedMicrophoneAudioURL: cleanedMicrophoneAudioURL,
            durationSeconds: playbackDurationSeconds,
            sourceAlignment: metadata.sourceAlignment,
            captureReport: metadata.captureReport,
            speechEngine: metadata.speechEngine,
            speechEngineWasCaptured: metadata.speechEngineWasCaptured,
            previewSpeechEngine: metadata.previewSpeechEngine,
            startContext: metadata.startContext,
            calendarEventSnapshot: metadata.calendarEventSnapshot
        )
    }

    private static func probedDurationSeconds(
        at url: URL,
        fileManager: FileManager
    ) -> TimeInterval? {
        guard hasNonEmptyFile(at: url, fileManager: fileManager),
            let file = try? AVAudioFile(forReading: url),
            file.length > 0
        else {
            return nil
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let duration = Double(file.length) / sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private static func hasNonEmptyFile(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard hasFile(at: url, fileManager: fileManager),
            let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else {
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

    public static func == (lhs: MeetingRecordingOutput, rhs: MeetingRecordingOutput) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.displayName == rhs.displayName
            && lhs.folderURL == rhs.folderURL
            && lhs.mixedAudioURL == rhs.mixedAudioURL
            && lhs.microphoneAudioURL == rhs.microphoneAudioURL
            && lhs.systemAudioURL == rhs.systemAudioURL
            && lhs.cleanedMicrophoneAudioURL == rhs.cleanedMicrophoneAudioURL
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.sourceAlignment == rhs.sourceAlignment
            && lhs.captureReport == rhs.captureReport
            && lhs.speechEngine == rhs.speechEngine
            && lhs.speechEngineWasCaptured == rhs.speechEngineWasCaptured
            && lhs.previewSpeechEngine == rhs.previewSpeechEngine
            && lhs.startContext == rhs.startContext
            && lhs.userNotes == rhs.userNotes
            && lhs.calendarEventSnapshot == rhs.calendarEventSnapshot
    }
}

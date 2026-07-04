import AVFoundation
import CoreMedia
import Foundation
import OSLog

public enum MeetingRecordingRecoveryError: Error, LocalizedError, Sendable {
    case missingSessionFolder
    case noRecoverableAudio
    case audioRepairFailed(String)
    case mixFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSessionFolder:
            return "The interrupted recording folder no longer exists."
        case .noRecoverableAudio:
            return "No recoverable meeting audio was found."
        case .audioRepairFailed(let message):
            return "The interrupted recording audio could not be repaired: \(message)"
        case .mixFailed(let message):
            return "The recovered meeting audio could not be combined: \(message)"
        }
    }
}

public protocol MeetingRecordingRecoveryServicing: Sendable {
    func discoverPendingRecoveries() async throws -> [MeetingRecordingLockFile]
    func recover(_ lock: MeetingRecordingLockFile) async throws -> Transcription
    func discard(_ lock: MeetingRecordingLockFile) async throws
}

public final class MeetingRecordingRecoveryService: MeetingRecordingRecoveryServicing, @unchecked Sendable {
    private struct RecoverableSource {
        let source: AudioSource
        let url: URL
        let duration: TimeInterval
        let sampleRate: Double
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingRecordingRecoveryService")

    private let meetingsRoot: URL
    private let lockFileStore: MeetingRecordingLockFileStoring
    private let transcriptionService: TranscriptionServiceProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let settlement: MeetingRecordingSettlement
    private let audioConverter: AudioFileConverting
    private let fileManager: FileManager
    /// Builds the echo suppressor used to re-derive `microphone-cleaned.m4a`
    /// during recovery when trustworthy source alignment is available. Set from
    /// the injected `echoSuppressionConfiguration`; resolves to passthrough
    /// (→ no cleaned file) without bundled AEC assets.
    private let micConditionerFactory: @Sendable () -> any MicConditioning
    private let recordingDurationProvider: @Sendable ([TimeInterval], Date) -> TimeInterval

    public convenience init(
        meetingsRoot: URL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true),
        lockFileStore: MeetingRecordingLockFileStoring = MeetingRecordingLockFileStore(),
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        audioConverter: AudioFileConverting = AudioFileConverter(),
        fileManager: FileManager = .default,
        echoSuppressionConfiguration: MeetingEchoSuppressionConfiguration = .fromEnvironment()
    ) {
        self.init(
            meetingsRoot: meetingsRoot,
            lockFileStore: lockFileStore,
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            audioConverter: audioConverter,
            fileManager: fileManager,
            micConditionerFactory: {
                MeetingEchoSuppressionFactory.makeConditioner(
                    configuration: echoSuppressionConfiguration)
            }
        )
    }

    init(
        meetingsRoot: URL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true),
        lockFileStore: MeetingRecordingLockFileStoring = MeetingRecordingLockFileStore(),
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        settlement: MeetingRecordingSettlement? = nil,
        audioConverter: AudioFileConverting = AudioFileConverter(),
        fileManager: FileManager = .default,
        micConditionerFactory: @escaping @Sendable () -> any MicConditioning,
        recordingDurationProvider: @escaping @Sendable ([TimeInterval], Date) -> TimeInterval = { sourceDurations, startedAt in
            sourceDurations.max() ?? max(0, Date().timeIntervalSince(startedAt))
        }
    ) {
        self.meetingsRoot = meetingsRoot
        self.lockFileStore = lockFileStore
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        self.settlement =
            settlement
            ?? MeetingRecordingSettlement(
                lockFileStore: lockFileStore,
                transcriptionRepo: transcriptionRepo
            )
        self.audioConverter = audioConverter
        self.fileManager = fileManager
        self.micConditionerFactory = micConditionerFactory
        self.recordingDurationProvider = recordingDurationProvider
    }

    /// Minimum size (bytes) for either `microphone.m4a` or `system.m4a` to
    /// be considered worth offering recovery on. AAC fragmented-MP4 init
    /// headers (no audio frames) are ~557 bytes; even a fraction of a second
    /// of compressed audio is several KB. The threshold is comfortably above
    /// the empty-header floor and well below any meaningful recording.
    ///
    /// Sessions whose audio is at or below this floor were almost always
    /// killed within a second of `MeetingRecordingService.startRecording`
    /// writing the lock file but before any real audio frames were captured -
    /// e.g., a force-quit, hard crash, or rapid dev-cycle restart. Surfacing
    /// these as "interrupted recordings" alarms the user over data that
    /// never existed and where `recover()` would error with
    /// `noRecoverableAudio` regardless. Filtering at discovery is cheaper
    /// (size stat, no AVFoundation load) and preserves the existing public
    /// contract: every entry returned here is something `recover()` has a
    /// chance of producing a transcription from.
    public static let minViableAudioBytes: Int = 4 * 1024

    public func discoverPendingRecoveries() async throws -> [MeetingRecordingLockFile] {
        // `discoverOrphans` already sorts by `startedAt` with a folder-path
        // tiebreaker for ties — re-sorting here would just drop the
        // tiebreaker without adding any ordering guarantee.
        let candidates = try lockFileStore.discoverOrphans(meetingsRoot: meetingsRoot)
        var viable: [MeetingRecordingLockFile] = []
        viable.reserveCapacity(candidates.count)
        for lock in candidates {
            do {
                if try canOfferRecovery(for: lock) {
                    viable.append(lock)
                } else {
                    logger.info(
                        "meeting_recovery_skipped_empty_session session=\(lock.sessionId.uuidString, privacy: .public)"
                    )
                }
            } catch {
                logger.error(
                    "meeting_recovery_viability_check_failed session=\(lock.sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                viable.append(lock)
            }
        }
        return viable
    }

    private func canOfferRecovery(for lock: MeetingRecordingLockFile) throws -> Bool {
        guard let folderURL = lock.folderURL else { return false }
        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        if try existingCompletedTranscription(for: mixedURL) != nil {
            return true
        }
        return hasViableAudio(in: lock)
    }

    private func hasViableAudio(in lock: MeetingRecordingLockFile) -> Bool {
        guard let folderURL = lock.folderURL else { return false }
        let micSize = fileSize(at: folderURL.appendingPathComponent("microphone.m4a"))
        let sysSize = fileSize(at: folderURL.appendingPathComponent("system.m4a"))
        return max(micSize, sysSize) >= Self.minViableAudioBytes
    }

    public func recover(_ lock: MeetingRecordingLockFile) async throws -> Transcription {
        guard let folderURL = lock.folderURL else {
            throw MeetingRecordingRecoveryError.missingSessionFolder
        }
        guard fileManager.fileExists(atPath: folderURL.path) else {
            throw MeetingRecordingRecoveryError.missingSessionFolder
        }

        let microphoneURL = folderURL.appendingPathComponent("microphone.m4a")
        let systemURL = folderURL.appendingPathComponent("system.m4a")
        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")

        if let existing = try existingCompletedTranscription(for: mixedURL) {
            await writeNotesSidecar(for: lock, folderURL: folderURL)
            return try await completeExistingTranscription(existing, folderURL: folderURL, lock: lock)
        }
        let incompleteRows = try existingIncompleteTranscriptions(for: mixedURL)
        let rowToUpdate = selectedIncompleteTranscription(from: incompleteRows)
        try deleteDuplicateIncompleteTranscriptions(incompleteRows, keeping: rowToUpdate?.id)

        var recoveredSources: [RecoverableSource] = []
        for (source, url) in [(AudioSource.microphone, microphoneURL), (.system, systemURL)] {
            guard fileManager.fileExists(atPath: url.path), fileSize(at: url) > 0 else { continue }
            do {
                let repaired = try await repairIfNeeded(url)
                recoveredSources.append(
                    RecoverableSource(
                        source: source,
                        url: repaired.url,
                        duration: repaired.duration,
                        sampleRate: repaired.sampleRate
                    )
                )
            } catch {
                logger.error("meeting_recovery_source_skipped session=\(lock.sessionId.uuidString, privacy: .public) source=\(String(describing: source), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        guard !recoveredSources.isEmpty else {
            throw MeetingRecordingRecoveryError.noRecoverableAudio
        }

        let sourceAlignment = makeRecoveredAlignment(from: recoveredSources)
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: sourceAlignment,
                speechEngine: lock.speechEngine,
                startContext: lock.startContext,
                calendarEventSnapshot: lock.calendarEventSnapshot
            ),
            folderURL: folderURL
        )

        await writeNotesSidecar(for: lock, folderURL: folderURL)

        do {
            try await audioConverter.mixToM4A(
                inputURLs: recoveredSources.map(\.url),
                outputURL: mixedURL,
                sourceAlignment: sourceAlignment
            )
        } catch {
            logger.error("meeting_recovery_mix_failed_nonfatal session=\(lock.sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        let recoveredBySource = Dictionary(
            recoveredSources.map { ($0.source, $0.url) }, uniquingKeysWith: { first, _ in first })
        // Clamp the provider output to non-negative. If the user's clock
        // skewed backwards between lock-file write and recovery, fallback
        // wall-clock duration can otherwise corrupt the recovered output.
        let duration = max(0, recordingDurationProvider(recoveredSources.map(\.duration), lock.startedAt))
        let cleanedMicrophoneReadiness = scheduleCleanedMicrophoneRender(
            folderURL: folderURL,
            microphoneURL: recoveredBySource[.microphone],
            systemURL: recoveredBySource[.system],
            sourceAlignment: sourceAlignment,
            sessionID: lock.sessionId,
            recordingDuration: duration
        )

        let recording = MeetingRecordingOutput(
            sessionID: lock.sessionId,
            displayName: lock.displayName,
            folderURL: folderURL,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: systemURL,
            cleanedMicrophoneAudioURL: cleanedMicrophoneReadiness.outputURL,
            cleanedMicrophoneReadiness: cleanedMicrophoneReadiness,
            durationSeconds: duration,
            sourceAlignment: sourceAlignment,
            speechEngine: lock.speechEngine,
            startContext: lock.startContext,
            userNotes: lock.notes,
            calendarEventSnapshot: lock.calendarEventSnapshot
        )

        do {
            let transcription: Transcription
            if let rowToUpdate {
                transcription = try await transcriptionService.finalizeMeetingTranscription(
                    recording: recording,
                    updating: rowToUpdate.id,
                    onProgress: nil
                )
            } else {
                transcription = try await transcriptionService.transcribeMeeting(recording: recording, onProgress: nil)
            }
            return try await completeRecovery(transcription, folderURL: folderURL, lock: lock)
        } catch {
            logger.error("meeting_recovery_transcription_failed session=\(lock.sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func discard(_ lock: MeetingRecordingLockFile) async throws {
        guard let folderURL = lock.folderURL else { return }
        if fileManager.fileExists(atPath: folderURL.path) {
            let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
            if let completed = try existingCompletedTranscription(for: mixedURL) {
                try await settlement.settleCompletedTranscription(
                    folderURL: folderURL,
                    transcriptionID: completed.id,
                    sessionID: lock.sessionId
                )
                logger.info("meeting_recovery_discard_cleaned_completed_session session=\(lock.sessionId.uuidString, privacy: .public)")
                return
            }
            try fileManager.removeItem(at: folderURL)
        }
    }

    /// Re-derive `microphone-cleaned.m4a` from recovered mic + system audio on
    /// the same readiness gate as the normal stop path. Recovery does not block
    /// here; final STT owns the bounded wait and observable raw fallback.
    private func scheduleCleanedMicrophoneRender(
        folderURL: URL,
        microphoneURL: URL?,
        systemURL: URL?,
        sourceAlignment: MeetingSourceAlignment,
        sessionID: UUID,
        recordingDuration: TimeInterval
    ) -> MeetingCleanedMicrophoneReadiness {
        let outputURL = folderURL.appendingPathComponent(
            MeetingCleanedMicRenderer.cleanedMicrophoneFileName)
        guard MeetingCleanedMicrophoneReadinessPolicy.production.shouldAttemptRender(
            for: recordingDuration
        ) else {
            return MeetingCleanedMicrophoneRenderScheduler.skipPredictedRenderTimeout(
                outputURL: outputURL,
                sessionID: sessionID,
                fileManager: fileManager,
                eventName: "meeting_recovery_cleaned_mic"
            )
        }
        return MeetingCleanedMicrophoneRenderScheduler.schedule(
            outputURL: outputURL,
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            sourceAlignment: sourceAlignment,
            sessionID: sessionID,
            conditionerFactory: micConditionerFactory,
            fileManager: fileManager,
            eventName: "meeting_recovery_cleaned_mic"
        )
    }

    private func makeRecoveredAlignment(
        from sources: [RecoverableSource]
    ) -> MeetingSourceAlignment {
        func track(for source: AudioSource) -> MeetingSourceAlignment.Track? {
            guard let source = sources.first(where: { $0.source == source }) else { return nil }
            return MeetingSourceAlignment.Track(
                firstHostTime: nil,
                lastHostTime: nil,
                startOffsetMs: 0,
                writtenFrameCount: Int64((source.duration * source.sampleRate).rounded()),
                sampleRate: source.sampleRate
            )
        }

        return MeetingSourceAlignment(
            meetingOriginHostTime: nil,
            microphone: track(for: .microphone),
            system: track(for: .system)
        )
    }

    private func writeNotesSidecar(for lock: MeetingRecordingLockFile, folderURL: URL) async {
        do {
            try await MeetingNotesFile.write(
                notes: lock.notes,
                displayName: lock.displayName,
                to: folderURL,
                fileManager: MeetingNotesFile.SendableFileManager(fileManager)
            )
        } catch {
            logger.warning("meeting_notes_file_write_failed session=\(lock.sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func existingCompletedTranscription(for mixedURL: URL) throws -> Transcription? {
        try existingTranscriptions(for: mixedURL).first {
            $0.sourceType == .meeting
                && $0.status == .completed
        }
    }

    private func existingTranscriptions(for mixedURL: URL) throws -> [Transcription] {
        var seenIDs = Set<UUID>()
        var transcriptions: [Transcription] = []
        for path in MeetingArtifactPathAliases.aliases(for: mixedURL) {
            for transcription in try transcriptionRepo.fetchByFilePath(path, sourceType: .meeting) {
                guard seenIDs.insert(transcription.id).inserted else { continue }
                transcriptions.append(transcription)
            }
        }
        return transcriptions
    }

    private func existingIncompleteTranscriptions(for mixedURL: URL) throws -> [Transcription] {
        try existingTranscriptions(for: mixedURL)
            .filter { $0.status != .completed }
    }

    private func selectedIncompleteTranscription(from rows: [Transcription]) -> Transcription? {
        rows.sorted { lhs, rhs in
            let lhsPriority = incompleteRecoveryPriority(lhs.status)
            let rhsPriority = incompleteRecoveryPriority(rhs.status)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.createdAt > rhs.createdAt
        }.first
    }

    private func incompleteRecoveryPriority(_ status: Transcription.TranscriptionStatus) -> Int {
        switch status {
        case .processing:
            return 0
        case .error:
            return 1
        case .cancelled:
            return 2
        case .completed:
            return 3
        }
    }

    private func deleteDuplicateIncompleteTranscriptions(
        _ incomplete: [Transcription],
        keeping keptID: UUID?
    ) throws {
        for transcription in incomplete {
            guard transcription.id != keptID else { continue }
            _ = try transcriptionRepo.delete(id: transcription.id)
        }
    }

    private func completeExistingTranscription(
        _ transcription: Transcription,
        folderURL: URL,
        lock: MeetingRecordingLockFile
    ) async throws -> Transcription {
        if lock.state == .awaitingTranscription {
            try await settlement.settleCompletedTranscription(
                folderURL: folderURL,
                transcriptionID: transcription.id,
                sessionID: lock.sessionId
            )
            logger.info("meeting_recovery_cleaned_completed_session session=\(lock.sessionId.uuidString, privacy: .public)")
            return transcription
        }
        return try await completeRecovery(transcription, folderURL: folderURL, lock: lock)
    }

    private func completeRecovery(
        _ transcription: Transcription,
        folderURL: URL,
        lock: MeetingRecordingLockFile
    ) async throws -> Transcription {
        var recovered = transcription
        recovered.recoveredFromCrash = true
        // Carry forward any notes the user typed during the meeting (ADR-020 §9).
        // Lock file's `notes` is `nil` for pre-v0.8 recordings or recordings
        // where the user typed nothing. We only overwrite when the lock file
        // actually has notes — never clobber notes a recovered transcription
        // somehow already carries.
        if let lockNotes = lock.notes, recovered.userNotes == nil {
            recovered.userNotes = lockNotes
        }
        recovered.updatedAt = Date()
        try transcriptionRepo.save(recovered)
        try await settlement.settleCompletedTranscription(
            folderURL: folderURL,
            transcriptionID: recovered.id,
            sessionID: lock.sessionId
        )
        logger.info("meeting_recovery_completed session=\(lock.sessionId.uuidString, privacy: .public)")
        return recovered
    }

    private func repairIfNeeded(_ url: URL) async throws -> (url: URL, duration: TimeInterval, sampleRate: Double) {
        if let info = try? await loadAudioInfo(url), info.duration > 0 {
            return (url, info.duration, info.sampleRate)
        }

        let repairedURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-repaired.m4a")
        try? fileManager.removeItem(at: repairedURL)

        guard let exportSession = AVAssetExportSession(
            asset: AVURLAsset(url: url),
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw MeetingRecordingRecoveryError.audioRepairFailed("Unable to create export session.")
        }
        exportSession.outputURL = repairedURL
        exportSession.outputFileType = .m4a
        await exportSession.export()

        if let error = exportSession.error {
            throw MeetingRecordingRecoveryError.audioRepairFailed(error.localizedDescription)
        }
        guard exportSession.status == .completed,
              let info = try? await loadAudioInfo(repairedURL),
              info.duration > 0
        else {
            throw MeetingRecordingRecoveryError.audioRepairFailed("Export did not produce playable audio.")
        }

        // Atomic swap: the original is preserved if the OS-level move fails,
        // so a disk-full / sandbox blip during repair can't strand the user
        // without either copy of the audio. Same pattern as BinaryBootstrap.
        _ = try fileManager.replaceItemAt(url, withItemAt: repairedURL)
        return (url, info.duration, info.sampleRate)
    }

    private func loadAudioInfo(_ url: URL) async throws -> (duration: TimeInterval, sampleRate: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw MeetingRecordingRecoveryError.noRecoverableAudio
        }
        let duration = try await asset.load(.duration)
        let sampleRate = try await loadSampleRate(from: track) ?? 48_000.0
        return (duration.seconds.isFinite ? duration.seconds : 0, sampleRate)
    }

    private func loadSampleRate(from track: AVAssetTrack) async throws -> Double? {
        let formatDescriptions = try await track.load(.formatDescriptions)
        for description in formatDescriptions {
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                continue
            }
            let sampleRate = streamDescription.pointee.mSampleRate
            guard sampleRate.isFinite, sampleRate > 0 else { continue }
            return sampleRate
        }
        return nil
    }

    private func fileSize(at url: URL) -> Int {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }
}

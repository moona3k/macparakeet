import AVFoundation
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
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingRecordingRecoveryService")

    private let meetingsRoot: URL
    private let lockFileStore: MeetingRecordingLockFileStoring
    private let transcriptionService: TranscriptionServiceProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let audioConverter: AudioFileConverting
    private let fileManager: FileManager

    public init(
        meetingsRoot: URL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true),
        lockFileStore: MeetingRecordingLockFileStoring = MeetingRecordingLockFileStore(),
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        audioConverter: AudioFileConverting = AudioFileConverter(),
        fileManager: FileManager = .default
    ) {
        self.meetingsRoot = meetingsRoot
        self.lockFileStore = lockFileStore
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        self.audioConverter = audioConverter
        self.fileManager = fileManager
    }

    public func discoverPendingRecoveries() async throws -> [MeetingRecordingLockFile] {
        try lockFileStore.discoverOrphans(meetingsRoot: meetingsRoot)
            .sorted { $0.startedAt < $1.startedAt }
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
            return try completeExistingTranscription(existing, folderURL: folderURL, lock: lock)
        }
        try deleteIncompleteTranscriptions(for: mixedURL)

        var recoveredSources: [(source: AudioSource, url: URL, duration: TimeInterval)] = []
        for (source, url) in [(AudioSource.microphone, microphoneURL), (.system, systemURL)] {
            guard fileManager.fileExists(atPath: url.path), fileSize(at: url) > 0 else { continue }
            do {
                let repaired = try await repairIfNeeded(url)
                recoveredSources.append((source, repaired.url, repaired.duration))
            } catch {
                logger.error("meeting_recovery_source_skipped session=\(lock.sessionId.uuidString, privacy: .public) source=\(String(describing: source), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        guard !recoveredSources.isEmpty else {
            throw MeetingRecordingRecoveryError.noRecoverableAudio
        }

        let sourceAlignment = makeRecoveredAlignment(from: recoveredSources)
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(sourceAlignment: sourceAlignment),
            folderURL: folderURL
        )

        do {
            try await audioConverter.mixToM4A(
                inputURLs: recoveredSources.map(\.url),
                outputURL: mixedURL
            )
        } catch {
            logger.error("meeting_recovery_mix_failed session=\(lock.sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw MeetingRecordingRecoveryError.mixFailed(error.localizedDescription)
        }

        let duration = recoveredSources.map(\.duration).max() ?? Date().timeIntervalSince(lock.startedAt)
        let recording = MeetingRecordingOutput(
            sessionID: lock.sessionId,
            displayName: lock.displayName,
            folderURL: folderURL,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: systemURL,
            durationSeconds: duration,
            sourceAlignment: sourceAlignment
        )

        do {
            let transcription = try await transcriptionService.transcribeMeeting(recording: recording, onProgress: nil)
            return try completeRecovery(transcription, folderURL: folderURL, lock: lock)
        } catch {
            logger.error("meeting_recovery_transcription_failed session=\(lock.sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func discard(_ lock: MeetingRecordingLockFile) async throws {
        guard let folderURL = lock.folderURL else { return }
        if fileManager.fileExists(atPath: folderURL.path) {
            let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
            if try existingCompletedTranscription(for: mixedURL) != nil {
                try lockFileStore.delete(folderURL: folderURL)
                logger.info("meeting_recovery_discard_cleaned_completed_session session=\(lock.sessionId.uuidString, privacy: .public)")
                return
            }
            try fileManager.removeItem(at: folderURL)
        }
    }

    private func makeRecoveredAlignment(
        from sources: [(source: AudioSource, url: URL, duration: TimeInterval)]
    ) -> MeetingSourceAlignment {
        func track(for source: AudioSource) -> MeetingSourceAlignment.Track? {
            guard let source = sources.first(where: { $0.source == source }) else { return nil }
            let sampleRate = 48_000.0
            return MeetingSourceAlignment.Track(
                firstHostTime: nil,
                lastHostTime: nil,
                startOffsetMs: 0,
                writtenFrameCount: Int64((source.duration * sampleRate).rounded()),
                sampleRate: sampleRate
            )
        }

        return MeetingSourceAlignment(
            meetingOriginHostTime: nil,
            microphone: track(for: .microphone),
            system: track(for: .system)
        )
    }

    private func existingCompletedTranscription(for mixedURL: URL) throws -> Transcription? {
        try existingTranscriptions(for: mixedURL).first {
            $0.sourceType == .meeting
                && $0.status == .completed
        }
    }

    private func existingTranscriptions(for mixedURL: URL) throws -> [Transcription] {
        try transcriptionRepo.fetchAll(limit: nil).filter {
            $0.sourceType == .meeting
                && $0.filePath == mixedURL.path
        }
    }

    private func deleteIncompleteTranscriptions(for mixedURL: URL) throws {
        let incomplete = try existingTranscriptions(for: mixedURL)
            .filter { $0.status != .completed }
        for transcription in incomplete {
            _ = try transcriptionRepo.delete(id: transcription.id)
        }
    }

    private func completeExistingTranscription(
        _ transcription: Transcription,
        folderURL: URL,
        lock: MeetingRecordingLockFile
    ) throws -> Transcription {
        if lock.state == .awaitingTranscription {
            try lockFileStore.delete(folderURL: folderURL)
            logger.info("meeting_recovery_cleaned_completed_session session=\(lock.sessionId.uuidString, privacy: .public)")
            return transcription
        }
        return try completeRecovery(transcription, folderURL: folderURL, lock: lock)
    }

    private func completeRecovery(
        _ transcription: Transcription,
        folderURL: URL,
        lock: MeetingRecordingLockFile
    ) throws -> Transcription {
        var recovered = transcription
        recovered.recoveredFromCrash = true
        recovered.updatedAt = Date()
        try transcriptionRepo.save(recovered)
        try lockFileStore.delete(folderURL: folderURL)
        logger.info("meeting_recovery_completed session=\(lock.sessionId.uuidString, privacy: .public)")
        return recovered
    }

    private func repairIfNeeded(_ url: URL) async throws -> (url: URL, duration: TimeInterval) {
        if let duration = try? await loadDuration(url), duration > 0 {
            return (url, duration)
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
              let duration = try? await loadDuration(repairedURL),
              duration > 0
        else {
            throw MeetingRecordingRecoveryError.audioRepairFailed("Export did not produce playable audio.")
        }

        try? fileManager.removeItem(at: url)
        try fileManager.moveItem(at: repairedURL, to: url)
        return (url, duration)
    }

    private func loadDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw MeetingRecordingRecoveryError.noRecoverableAudio
        }
        let duration = try await asset.load(.duration)
        return duration.seconds.isFinite ? duration.seconds : 0
    }

    private func fileSize(at url: URL) -> Int {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }
}

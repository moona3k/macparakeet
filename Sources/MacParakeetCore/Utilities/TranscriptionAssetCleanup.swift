import Foundation
import os

public enum TranscriptionAssetCleanupError: Error, LocalizedError {
    case removalFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .removalFailed(_, let reason):
            return "Could not remove app-owned audio: \(reason)"
        }
    }
}

public struct MeetingAudioDetachResult: Sendable {
    public let removedOwnedAudio: Bool
    public let hadAudioPath: Bool

    public var detached: Bool {
        removedOwnedAudio || !hadAudioPath
    }
}

public enum TranscriptionAssetCleanup {
    public static let unmanagedMeetingAudioMessage =
        "Meeting audio is not stored in MacParakeet's managed recordings folder."

    private static let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "TranscriptionAssetCleanup"
    )
    private static let standardMeetingAudioFileNames: Set<String> = [
        "meeting.m4a",
        "microphone.m4a",
        "system.m4a",
    ]
    private static let managedMeetingAudioExtensions: Set<String> = [
        "aac",
        "caf",
        "flac",
        "m4a",
        "mp3",
        "wav",
    ]

    public static func isStandardMeetingAudioFileName(_ fileName: String) -> Bool {
        standardMeetingAudioFileNames.contains(fileName)
    }

    public static func removeOwnedAssets(
        for transcription: Transcription,
        fileManager: FileManager = .default
    ) throws {
        switch transcription.sourceType {
        case .youtube, .podcast:
            // Both downloaded-media sources store their audio under the shared
            // app-managed downloads directory; the same prefix guard applies.
            guard let filePath = transcription.filePath, !filePath.isEmpty else { return }
            try removeDownloadedMediaFile(at: URL(fileURLWithPath: filePath), fileManager: fileManager)
        case .meeting:
            _ = try removeOwnedMeetingAudio(for: transcription, fileManager: fileManager)
        case .file:
            return
        }
    }

    @discardableResult
    public static func removeOwnedMeetingAudio(
        for transcription: Transcription,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard transcription.sourceType == .meeting,
              let folderURL = MeetingArtifactStore.sessionFolderURL(for: transcription)?.standardizedFileURL else {
            return false
        }

        return try removeMeetingFolder(at: folderURL, fileManager: fileManager)
    }

    @discardableResult
    public static func detachOwnedMeetingAudio(
        for transcription: Transcription,
        repository: TranscriptionRepositoryProtocol,
        fileManager: FileManager = .default
    ) throws -> MeetingAudioDetachResult {
        let hasAudioPath = !(transcription.filePath?.isEmpty ?? true)
        guard hasAudioPath else {
            let result = MeetingAudioDetachResult(removedOwnedAudio: false, hadAudioPath: false)
            try repository.updateFilePath(id: transcription.id, filePath: nil)
            return result
        }
        guard let removalPlan = try meetingAudioRemovalPlan(for: transcription, fileManager: fileManager) else {
            return MeetingAudioDetachResult(removedOwnedAudio: false, hadAudioPath: true)
        }

        try repository.updateMeetingArtifactFolderPath(
            id: transcription.id,
            folderPath: removalPlan.folderURL.path
        )
        try removeMeetingAudioFiles(removalPlan, fileManager: fileManager)
        try repository.updateFilePath(id: transcription.id, filePath: nil)
        return MeetingAudioDetachResult(removedOwnedAudio: true, hadAudioPath: true)
    }

    private static func meetingAudioRemovalPlan(
        for transcription: Transcription,
        fileManager: FileManager
    ) throws -> MeetingAudioRemovalPlan? {
        guard transcription.sourceType == .meeting,
              let filePath = transcription.filePath,
              !filePath.isEmpty else {
            return nil
        }

        let mixedAudioURL = URL(fileURLWithPath: filePath).standardizedFileURL
        let folderURL = (MeetingArtifactStore.sessionFolderURL(for: transcription)
            ?? mixedAudioURL.deletingLastPathComponent())
            .standardizedFileURL

        guard isKnownMeetingFolder(folderURL, fileManager: fileManager) else {
            logger.warning(
                "Refusing to remove meeting audio outside app support: \(folderURL.path, privacy: .private)"
            )
            return nil
        }
        let lockURL = MeetingRecordingLockFileStore.lockFileURL(for: folderURL)
        guard !fileManager.fileExists(atPath: lockURL.path) else {
            logger.warning(
                "Refusing to remove audio from locked meeting folder: \(folderURL.path, privacy: .private)"
            )
            throw TranscriptionAssetCleanupError.removalFailed(
                path: folderURL.path,
                reason: "meeting audio is still awaiting transcription or recovery"
            )
        }

        return MeetingAudioRemovalPlan(
            folderURL: folderURL,
            candidates: meetingAudioFileCandidates(mixedAudioURL: mixedAudioURL, folderURL: folderURL)
        )
    }

    private static func removeMeetingAudioFiles(
        _ plan: MeetingAudioRemovalPlan,
        fileManager: FileManager
    ) throws {
        for candidate in plan.candidates where fileManager.fileExists(atPath: candidate.path) {
            try removeItem(at: candidate, fileManager: fileManager)
        }
    }

    private static func meetingAudioFileCandidates(mixedAudioURL: URL, folderURL: URL) -> Set<URL> {
        var candidates = Set(
            standardMeetingAudioFileNames.map { folderURL.appendingPathComponent($0).standardizedFileURL }
        )
        if mixedAudioURL.deletingLastPathComponent().standardizedFileURL == folderURL,
           managedMeetingAudioExtensions.contains(mixedAudioURL.pathExtension.lowercased()) {
            candidates.insert(mixedAudioURL)
        }
        return candidates
    }

    public static func removeManagedMeetingAudioFiles(
        under directoryPath: String,
        fileManager: FileManager = .default
    ) throws {
        let rootURL = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        guard fileManager.fileExists(atPath: rootURL.path) else { return }

        let sessionURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )

        let sessionFolders = sessionURLs.compactMap { sessionURL -> URL? in
            guard let values = try? sessionURL.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { return nil }
            return sessionURL.standardizedFileURL
        }

        for folderURL in sessionFolders {
            let lockURL = MeetingRecordingLockFileStore.lockFileURL(for: folderURL)
            guard !fileManager.fileExists(atPath: lockURL.path) else {
                logger.warning(
                    "Refusing bulk audio cleanup while meeting folder is locked: \(folderURL.path, privacy: .private)"
                )
                throw TranscriptionAssetCleanupError.removalFailed(
                    path: folderURL.path,
                    reason: "meeting audio is still awaiting transcription or recovery"
                )
            }
        }

        for folderURL in sessionFolders {
            let plan = MeetingAudioRemovalPlan(
                folderURL: folderURL,
                candidates: Set(standardMeetingAudioFileNames.map {
                    folderURL.appendingPathComponent($0).standardizedFileURL
                })
            )
            try removeMeetingAudioFiles(plan, fileManager: fileManager)
        }
    }

    private static func removeDownloadedMediaFile(at fileURL: URL, fileManager: FileManager) throws {
        let downloadsRootURL = URL(fileURLWithPath: AppPaths.youtubeDownloadsDir, isDirectory: true)
            .standardizedFileURL
        let targetURL = fileURL.standardizedFileURL

        guard targetURL.path.hasPrefix(downloadsRootURL.path + "/") else {
            logger.warning(
                "Refusing to remove downloaded-media asset outside app support: \(targetURL.path, privacy: .private)"
            )
            return
        }

        try removeItem(at: targetURL, fileManager: fileManager)
    }

    @discardableResult
    private static func removeMeetingFolder(at folderURL: URL, fileManager: FileManager) throws -> Bool {
        guard isKnownMeetingFolder(folderURL, fileManager: fileManager) else {
            logger.warning(
                "Refusing to remove meeting folder outside app support: \(folderURL.path, privacy: .private)"
            )
            return false
        }
        let lockURL = MeetingRecordingLockFileStore.lockFileURL(for: folderURL)
        guard !fileManager.fileExists(atPath: lockURL.path) else {
            logger.warning(
                "Refusing to remove locked meeting folder: \(folderURL.path, privacy: .private)"
            )
            throw TranscriptionAssetCleanupError.removalFailed(
                path: folderURL.path,
                reason: "meeting audio is still awaiting transcription or recovery"
            )
        }
        try removeItem(at: folderURL, fileManager: fileManager)
        return true
    }

    private static func isKnownMeetingFolder(_ folderURL: URL, fileManager: FileManager) -> Bool {
        let knownRoots = [
            AppPaths.defaultMeetingRecordingsDir,
            AppPaths.meetingRecordingsDir,
        ].map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        if knownRoots.contains(where: { folderURL.path.hasPrefix($0.path + "/") }) {
            return true
        }
        if fileManager.fileExists(atPath: MeetingRecordingMetadataStore.metadataURL(for: folderURL).path) {
            return true
        }
        return hasMeetingArtifactManifest(in: folderURL)
    }

    private static func hasMeetingArtifactManifest(in folderURL: URL) -> Bool {
        let manifestURL = folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL) else { return false }
        return ((try? JSONDecoder().decode(MeetingArtifactManifestProbe.self, from: data))?.schema) == MeetingArtifactStore.schema
    }

    private static func removeItem(at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.warning(
                "Failed to remove transcription asset at \(url.path, privacy: .private): \(String(describing: error), privacy: .private)"
            )
            throw TranscriptionAssetCleanupError.removalFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }
}

private struct MeetingArtifactManifestProbe: Decodable {
    let schema: String
}

private struct MeetingAudioRemovalPlan {
    let folderURL: URL
    let candidates: Set<URL>
}

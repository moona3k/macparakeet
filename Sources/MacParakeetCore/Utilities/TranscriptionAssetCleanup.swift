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

    public static func removeOwnedAssets(
        for transcription: Transcription,
        fileManager: FileManager = .default
    ) throws {
        guard let filePath = transcription.filePath, !filePath.isEmpty else { return }

        switch transcription.sourceType {
        case .youtube, .podcast:
            // Both downloaded-media sources store their audio under the shared
            // app-managed downloads directory; the same prefix guard applies.
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
              let filePath = transcription.filePath,
              !filePath.isEmpty else {
            return false
        }

        return try removeMeetingFolder(containing: URL(fileURLWithPath: filePath), fileManager: fileManager)
    }

    @discardableResult
    public static func detachOwnedMeetingAudio(
        for transcription: Transcription,
        repository: TranscriptionRepositoryProtocol,
        fileManager: FileManager = .default
    ) throws -> MeetingAudioDetachResult {
        let hasAudioPath = !(transcription.filePath?.isEmpty ?? true)
        let removedOwnedAudio = try removeOwnedMeetingAudio(for: transcription, fileManager: fileManager)
        let result = MeetingAudioDetachResult(
            removedOwnedAudio: removedOwnedAudio,
            hadAudioPath: hasAudioPath
        )
        guard result.detached else { return result }

        try repository.updateFilePath(id: transcription.id, filePath: nil)
        return result
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
    private static func removeMeetingFolder(containing fileURL: URL, fileManager: FileManager) throws -> Bool {
        let folderURL = fileURL.deletingLastPathComponent().standardizedFileURL

        guard isKnownMeetingFolder(folderURL, fileManager: fileManager) else {
            logger.warning(
                "Refusing to remove meeting folder outside app support: \(folderURL.path, privacy: .private)"
            )
            return false
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

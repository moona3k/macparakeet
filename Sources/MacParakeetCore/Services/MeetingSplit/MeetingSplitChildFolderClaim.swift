import Darwin
import Foundation

/// A small durable marker written inside a claimed child folder, proving that
/// folder was created by this exact operation for this exact child. Named
/// with a leading dot so it never collides with a published meeting
/// artifact's own file names.
struct MeetingSplitChildFolderMarker: Codable, Equatable {
    static let fileName = ".meeting-split-child-marker.json"

    let operationId: UUID
    let childId: UUID
}

public enum MeetingSplitChildFolderClaimError: Error, Sendable, Equatable, LocalizedError {
    /// A path already exists at the child folder location and is either not a
    /// plain directory (for example a symlink) or does not carry this exact
    /// operation/child's own marker. Refused outright — this never deletes
    /// content it cannot positively identify as its own.
    case unexpectedExistingContent(path: String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedExistingContent(let path):
            return "Unexpected existing content at \(path); refusing to touch it."
        }
    }
}

/// Claims (creates, or safely reclaims) the on-disk folder for one split
/// child, and later verifies/removes it for discard — the only two places
/// permitted to delete a child folder before it is published. Every claim
/// leaves the child's own marker on disk immediately after creation, so a
/// later attempt (a resumed export, or discard) can positively verify the
/// folder is this operation's own before ever removing it. Callers must hold
/// both `MeetingSplitOperationLease` (for this operation) and
/// `MeetingMediaMutationLease` (for the recordings root) before calling
/// either function, so no writer can be racing the check.
enum MeetingSplitChildFolderClaim {
    /// Returns an exclusively owned, empty folder at `folderURL` ready for
    /// the exporter to write into.
    ///
    /// - If nothing exists at `folderURL`, it is created fresh and marked.
    /// - If a folder already exists there carrying exactly this operation's
    ///   and child's own marker, it is treated as an interrupted earlier
    ///   attempt at this same claim: removed and recreated.
    /// - Anything else (a non-directory, a symlink, a directory with no
    ///   marker or a different marker) fails safely without touching the
    ///   existing content.
    static func claim(
        operationId: UUID,
        childId: UUID,
        folderURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        if try reclaimIfOwnInterruptedAttempt(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: fileManager
        ) {
            try fileManager.removeItem(at: folderURL)
        }

        guard mkdir(folderURL.path, S_IRWXU) == 0 else {
            throw MeetingSplitChildFolderClaimError.unexpectedExistingContent(path: folderURL.path)
        }
        let marker = MeetingSplitChildFolderMarker(operationId: operationId, childId: childId)
        let markerData = try JSONEncoder().encode(marker)
        try markerData.write(to: folderURL.appendingPathComponent(MeetingSplitChildFolderMarker.fileName), options: .atomic)
        return folderURL
    }

    /// Removes `folderURL` only if it positively carries this operation's and
    /// child's own marker. Any unexpected existing content (missing marker,
    /// mismatched marker, non-directory, symlink) is left completely
    /// untouched — a discard/retry must never guess.
    static func removeIfOwn(
        operationId: UUID,
        childId: UUID,
        folderURL: URL,
        fileManager: FileManager
    ) throws {
        guard let marker = ownMarker(at: folderURL, fileManager: fileManager),
              marker == MeetingSplitChildFolderMarker(operationId: operationId, childId: childId)
        else {
            return
        }
        try fileManager.removeItem(at: folderURL)
    }

    /// `true` when `folderURL` exists, is a plain directory (never a
    /// symlink), and carries exactly this operation's and child's own marker
    /// — i.e. an earlier, interrupted attempt at this exact claim that is
    /// safe to clear and redo. Throws `.unexpectedExistingContent` for any
    /// other existing content instead of silently proceeding.
    private static func reclaimIfOwnInterruptedAttempt(
        operationId: UUID,
        childId: UUID,
        folderURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: folderURL.path) else { return false }
        guard let marker = ownMarker(at: folderURL, fileManager: fileManager),
              marker == MeetingSplitChildFolderMarker(operationId: operationId, childId: childId)
        else {
            throw MeetingSplitChildFolderClaimError.unexpectedExistingContent(path: folderURL.path)
        }
        return true
    }

    /// Reads and decodes the marker at `folderURL` only when `folderURL` is
    /// itself a plain directory (via `lstat`-equivalent attributes, so a
    /// symlink planted at the folder path is never followed and never
    /// treated as owned).
    private static func ownMarker(at folderURL: URL, fileManager: FileManager) -> MeetingSplitChildFolderMarker? {
        guard let resourceValues = try? folderURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              resourceValues.isSymbolicLink != true,
              resourceValues.isDirectory == true
        else {
            return nil
        }
        let markerURL = folderURL.appendingPathComponent(MeetingSplitChildFolderMarker.fileName)
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(MeetingSplitChildFolderMarker.self, from: data)
    }
}

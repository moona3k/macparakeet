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
    /// The exclusive publish rename itself failed for a reason other than
    /// something already existing at the destination (that case is always
    /// `.unexpectedExistingContent` instead, after checking for positively
    /// owned interrupted content) — for example a permissions or storage
    /// failure. Nothing was published at `path` because of this call.
    case publishFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedExistingContent(let path):
            return "Unexpected existing content at \(path); refusing to touch it."
        case .publishFailed(let path):
            return "Failed to publish the claimed folder at \(path)."
        }
    }
}

/// Claims (creates, or safely reclaims) the on-disk folder for one split
/// child, and later verifies/removes it for discard — the only two places
/// permitted to delete a child folder before it is published. Callers must
/// hold both `MeetingSplitOperationLease` (for this operation) and
/// `MeetingMediaMutationLease` (for the recordings root) before calling
/// either function, so no writer can be racing the check.
///
/// `claim` never creates the marker file inside the final destination
/// folder itself: it first builds a fully marked folder at a private,
/// fresh sibling scratch path, then publishes it to the
/// final destination with one exclusive atomic rename (`renamex_np` with
/// `RENAME_EXCL`, which fails rather than overwriting if the destination
/// already exists). This means the final path can never be observed
/// half-claimed — mkdir'd but not yet marked — after a crash: it is either
/// absent, or it is exactly this operation/child's own fully marked folder.
enum MeetingSplitChildFolderClaim {
    /// Returns an exclusively owned, empty folder at `folderURL` ready for
    /// the exporter to write into.
    ///
    /// - Builds a fresh, fully marked folder at a private sibling scratch
    ///   path, without touching any pre-existing scratch content, then publishes it to
    ///   `folderURL` with one exclusive atomic rename.
    /// - If `folderURL` already exists (the rename fails because of that),
    ///   the destination is reclaimed — removed and the scratch folder
    ///   re-published in its place — only when it positively carries this
    ///   same operation's and child's own marker, i.e. an interrupted earlier
    ///   attempt at this same claim (from before or after this scratch/
    ///   publish step existed).
    /// - Anything else at `folderURL` (a non-directory, a symlink, a
    ///   directory with no marker or a different marker) fails safely
    ///   without touching the existing content; the private scratch folder
    ///   is removed rather than left behind unpublished.
    static func claim(
        operationId: UUID,
        childId: UUID,
        folderURL: URL,
        fileManager: FileManager,
        writeMarker: (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) throws -> URL {
        let scratchURL = scratchFolderURL(operationId: operationId, childId: childId, besideFolderURL: folderURL)
        // Exclusive creation proves ownership for this invocation. A path's
        // name alone never authorizes removing pre-existing content. A fresh
        // attempt name also avoids blocking retry on an unmarked directory
        // left by a crash before marker creation. Scratch never contains audio.
        guard mkdir(scratchURL.path, S_IRWXU) == 0 else {
            throw MeetingSplitChildFolderClaimError.unexpectedExistingContent(path: scratchURL.path)
        }
        defer { try? fileManager.removeItem(at: scratchURL) }
        let marker = MeetingSplitChildFolderMarker(operationId: operationId, childId: childId)
        try writeMarker(
            JSONEncoder().encode(marker), scratchURL.appendingPathComponent(MeetingSplitChildFolderMarker.fileName))

        if publish(scratchURL: scratchURL, to: folderURL) {
            return folderURL
        }
        let publishErrno = errno
        guard publishErrno == EEXIST else {
            throw MeetingSplitChildFolderClaimError.publishFailed(path: folderURL.path)
        }

        // Something already exists at `folderURL`. Reclaim it only if it
        // positively carries this exact operation/child's own marker;
        // anything else is left completely untouched and the private
        // scratch folder is removed instead of left behind.
        guard isOwnMarkerFolder(operationId: operationId, childId: childId, folderURL: folderURL, fileManager: fileManager) else {
            throw MeetingSplitChildFolderClaimError.unexpectedExistingContent(path: folderURL.path)
        }
        try fileManager.removeItem(at: folderURL)
        guard publish(scratchURL: scratchURL, to: folderURL) else {
            throw MeetingSplitChildFolderClaimError.publishFailed(path: folderURL.path)
        }
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

    /// A fresh attempt path. Interrupted scratch directories are deliberately
    /// not reclaimed by name: they contain at most a marker, never audio.
    private static func scratchFolderURL(operationId: UUID, childId: UUID, besideFolderURL folderURL: URL) -> URL {
        folderURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".meeting-split-child-scratch-\(operationId.uuidString)-\(childId.uuidString)-\(UUID().uuidString)", isDirectory: true)
    }

    /// One exclusive, atomic rename: fails (returning `false`, with `errno ==
    /// EEXIST`) rather than overwriting or merging if `folderURL` already
    /// exists, so the destination is never observed in a half-published
    /// state and never silently loses existing content.
    private static func publish(scratchURL: URL, to folderURL: URL) -> Bool {
        renamex_np(scratchURL.path, folderURL.path, UInt32(RENAME_EXCL)) == 0
    }

    /// `true` when `folderURL` exists, is a plain directory (never a
    /// symlink), and carries exactly this operation's and child's own marker
    /// — i.e. an earlier, interrupted attempt at this exact claim that is
    /// safe to clear and redo.
    private static func isOwnMarkerFolder(
        operationId: UUID, childId: UUID, folderURL: URL, fileManager: FileManager
    ) -> Bool {
        guard let marker = ownMarker(at: folderURL, fileManager: fileManager) else { return false }
        return marker == MeetingSplitChildFolderMarker(operationId: operationId, childId: childId)
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

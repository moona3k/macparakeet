import Foundation

/// Resolves the on-disk audio file for a finalized meeting recording and
/// suggests an export-friendly filename.
///
/// Meeting transcriptions store the mixed-track `meeting.m4a` path in
/// `Transcription.filePath`. The file itself lives at
/// `~/Library/Application Support/MacParakeet/meeting-recordings/<sessionUUID>/meeting.m4a`
/// (see `MeetingAudioStorageWriter`).
///
/// This helper is the single seam between UI surfaces ("Show in Finder",
/// "Save Audio As…") and that on-disk layout, so future changes to the
/// folder structure only ripple through one file.
public enum MeetingAudioFile {
    public enum State: Equatable, Sendable {
        case notMeeting
        case saved
        case removed
        case missing
    }

    // MARK: - URL resolution

    /// Returns the mixed-track audio URL for a meeting transcription, or
    /// `nil` for non-meeting sources or transcriptions without a stored
    /// file path. Does NOT check on-disk existence; call
    /// `isAvailable(for:)` when that matters.
    public static func mixedAudioURL(for transcription: Transcription) -> URL? {
        guard transcription.sourceType == .meeting else { return nil }
        guard let path = transcription.filePath,
              !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Whether finalized meeting audio is reachable on disk. Returns false for
    /// non-meeting rows, actively processing rows, and missing audio files.
    public static func isAvailable(
        for transcription: Transcription,
        fileManager: FileManager = .default
    ) -> Bool {
        state(for: transcription, fileManager: fileManager) == .saved
    }

    /// User-facing availability state for a meeting's stored audio.
    ///
    /// `removed` means the DB no longer points at meeting audio, usually
    /// because the user chose audio-only cleanup or a retention policy removed
    /// it after final transcription. `missing` means the DB still points at a
    /// path, but that path is no longer a file on disk.
    public static func state(
        for transcription: Transcription,
        fileManager: FileManager = .default
    ) -> State {
        guard transcription.sourceType == .meeting,
              transcription.status != .processing else {
            return .notMeeting
        }
        guard let url = mixedAudioURL(for: transcription) else { return .removed }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && !isDirectory.boolValue {
            return .saved
        }
        return .missing
    }

    // MARK: - Safe copy

    /// Copy a meeting audio file from `source` to `destination`, with
    /// two guarantees the naive `FileManager.copyItem` does not give:
    ///
    /// 1. **No source destruction on same-file save.** A user can pick
    ///    the meeting's own folder in "Save Audio As…" and confirm an
    ///    overwrite of `meeting.m4a`. A pre-delete-then-copy approach
    ///    would erase the only source file and then fail the copy.
    ///    Here we detect identical paths and no-op.
    /// 2. **No mid-copy corruption.** Large meetings can be hundreds of
    ///    MB. We copy to a sibling temp file first, then atomically
    ///    swap via `FileManager.replaceItemAt`, so a disk-full or
    ///    permissions failure halfway through leaves the prior
    ///    destination (if any) intact.
    public static func safeCopy(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let normalizedSource = source.standardizedFileURL
        let normalizedDestination = destination.standardizedFileURL

        if normalizedSource.path == normalizedDestination.path {
            // Already at the destination — nothing to do.
            return
        }

        let parent = normalizedDestination.deletingLastPathComponent()
        let tempURL = parent.appendingPathComponent(
            ".\(normalizedDestination.lastPathComponent).macparakeet-save-\(UUID().uuidString)"
        )

        try fileManager.copyItem(at: normalizedSource, to: tempURL)
        do {
            if fileManager.fileExists(atPath: normalizedDestination.path) {
                _ = try fileManager.replaceItemAt(normalizedDestination, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: normalizedDestination)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - Filename derivation

    /// Suggested filename stem (no extension) for "Save Audio As…" flows.
    ///
    /// Strategy:
    /// - When an LLM-derived title is present, use `"<title> - yyyy-MM-dd"`
    ///   so two meetings titled `"Q4 planning sync"` on different days
    ///   stay distinct in a Downloads folder.
    /// - Otherwise fall back to `transcription.fileName`, which the
    ///   recording service already populates as a date-stamped display
    ///   name (`"Meeting May 11, 2026 at 1:32 PM"`); appending another
    ///   date would just create noise.
    public static func suggestedExportStem(for transcription: Transcription) -> String {
        let derived = transcription.derivedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !derived.isEmpty {
            let datePart = isoDateFormatter.string(from: transcription.createdAt)
            return sanitize("\(derived) - \(datePart)")
        }
        let fallback = transcription.fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitize(fallback.isEmpty ? "Meeting" : fallback)
    }

    // MARK: - Internals

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Hard cap on the suggested filename stem. Well under any practical
    /// filesystem path length (~1023 bytes on APFS) and avoids producing
    /// a Save panel default that scrolls off-screen when an LLM-derived
    /// title is unusually long. The cap is enforced on grapheme cluster
    /// count via `String.prefix(_:)` so we never break a composite
    /// emoji or combining-character sequence.
    static let maxStemLength: Int = 100

    private static func sanitize(_ input: String) -> String {
        // Strip characters that would break filenames on macOS (`/`,
        // NUL), confuse shell tools (control characters / newlines /
        // tabs), or read poorly in a Save panel preview. Unicode letters,
        // punctuation, and emoji pass through — Finder handles those
        // fine — and we deliberately do NOT strip bidi formatters since
        // they're legitimate inside Arabic/Hebrew titles.
        var disallowed = CharacterSet(charactersIn: "/:\\\"")
        disallowed.formUnion(.controlCharacters)

        let cleaned = input
            .components(separatedBy: disallowed)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let capped = cleaned.count <= maxStemLength
            ? cleaned
            : String(cleaned.prefix(maxStemLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)

        return capped.isEmpty ? "Meeting" : capped
    }
}

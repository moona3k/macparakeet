import Foundation
import OSLog

/// Supported formats for auto-saving transcripts to disk.
public enum AutoSaveFormat: String, Codable, CaseIterable, Sendable {
    case txt
    case md
    case srt
    case vtt
    case json

    public var displayName: String {
        switch self {
        case .txt: return "Plain Text (.txt)"
        case .md: return "Markdown (.md)"
        case .srt: return "SRT Subtitles (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .json: return "JSON (.json)"
        }
    }

    public var fileExtension: String { rawValue }
}

/// Distinguishes transcription vs meeting auto-save settings.
public enum AutoSaveScope: String, Sendable {
    case transcription
    case meeting

    public var enabledKey: String {
        switch self {
        case .transcription: return "autoSaveTranscripts"
        case .meeting: return "autoSaveMeetings"
        }
    }

    public var formatKey: String {
        switch self {
        case .transcription: return "autoSaveFormat"
        case .meeting: return "meetingAutoSaveFormat"
        }
    }

    public var folderBookmarkKey: String {
        switch self {
        case .transcription: return "autoSaveFolderBookmark"
        case .meeting: return "meetingAutoSaveFolderBookmark"
        }
    }
}

/// Automatically saves completed transcriptions to a user-chosen folder.
/// Reads configuration from UserDefaults; does nothing when auto-save is disabled
/// or no folder is configured.
@MainActor
public final class AutoSaveService {
    private let exportService: ExportServiceProtocol
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AutoSaveService")

    // Legacy keys kept for backward compatibility with existing SettingsViewModel references.
    public static let enabledKey = AutoSaveScope.transcription.enabledKey
    public static let formatKey = AutoSaveScope.transcription.formatKey
    public static let folderBookmarkKey = AutoSaveScope.transcription.folderBookmarkKey

    public init(
        exportService: ExportServiceProtocol? = nil,
        defaults: UserDefaults = .standard
    ) {
        Self.migrateLegacyMeetingSettingsIfNeeded(defaults: defaults)
        self.exportService = exportService ?? ExportService()
        self.defaults = defaults
    }

    /// Save the transcription if auto-save is enabled for the given scope.
    /// Failures are logged but never surfaced to the user.
    public func saveIfEnabled(_ transcription: Transcription, scope: AutoSaveScope = .transcription) {
        guard defaults.bool(forKey: scope.enabledKey) else { return }
        guard let folderURL = resolveFolder(scope: scope) else {
            logger.warning("Auto-save enabled but no valid folder configured for \(scope.rawValue).")
            return
        }

        let format = AutoSaveFormat(rawValue: defaults.string(forKey: scope.formatKey) ?? "md") ?? .md
        let fileURL = buildFileURL(for: transcription, format: format, in: folderURL)

        do {
            // Ensure the folder still exists
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            switch format {
            case .txt: try exportService.exportToTxt(transcription: transcription, url: fileURL)
            case .md: try exportService.exportToMarkdown(transcription: transcription, url: fileURL)
            case .srt: try exportService.exportToSRT(transcription: transcription, url: fileURL)
            case .vtt: try exportService.exportToVTT(transcription: transcription, url: fileURL)
            case .json: try exportService.exportToJSON(transcription: transcription, url: fileURL)
            }

            logger.info("Auto-saved \(scope.rawValue) transcript to \(fileURL.lastPathComponent)")
        } catch {
            logger.error("Auto-save failed for \(scope.rawValue): \(error.localizedDescription)")
        }
    }

    // MARK: - Folder Bookmark

    /// Resolve the stored bookmark data back to a URL for the given scope.
    /// Re-creates the bookmark if it has gone stale.
    public func resolveFolder(scope: AutoSaveScope = .transcription) -> URL? {
        guard let bookmarkData = defaults.data(forKey: scope.folderBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            if let refreshed = try? url.bookmarkData() {
                defaults.set(refreshed, forKey: scope.folderBookmarkKey)
            }
        }
        return url
    }

    /// Upgraded installs may already have transcription auto-save configured before
    /// meeting-specific settings existed. Copy those values once so meetings get
    /// their own explicit settings without requiring the user to revisit Settings.
    public static func migrateLegacyMeetingSettingsIfNeeded(defaults: UserDefaults = .standard) {
        copyIfMissing(from: enabledKey, to: AutoSaveScope.meeting.enabledKey, defaults: defaults)
        copyIfMissing(from: formatKey, to: AutoSaveScope.meeting.formatKey, defaults: defaults)
        copyIfMissing(from: folderBookmarkKey, to: AutoSaveScope.meeting.folderBookmarkKey, defaults: defaults)
    }

    private static func copyIfMissing(from sourceKey: String, to destinationKey: String, defaults: UserDefaults) {
        guard defaults.object(forKey: destinationKey) == nil,
              let value = defaults.object(forKey: sourceKey)
        else { return }
        defaults.set(value, forKey: destinationKey)
    }

    /// Store a folder URL as bookmark data. Returns the display path on success.
    @discardableResult
    public static func storeFolder(_ url: URL, scope: AutoSaveScope = .transcription, defaults: UserDefaults = .standard) -> String? {
        guard let data = try? url.bookmarkData() else { return nil }
        defaults.set(data, forKey: scope.folderBookmarkKey)
        return url.path
    }

    /// Clear the stored folder bookmark.
    public static func clearFolder(scope: AutoSaveScope = .transcription, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: scope.folderBookmarkKey)
    }

    // MARK: - Filename

    /// Build a deduplicated file URL for the given transcription.
    /// Format: `YYYY-MM-DD-HHmmss-<sanitized-name>.<ext>`
    ///
    /// Uses `transcription.fileName` for both transcriptions and meetings —
    /// the auto-saved filename should match what the user sees in the
    /// in-app library card. Calendar-driven meeting recordings (post-#135)
    /// carry the calendar event title (e.g. "Roadmap Sync") rather than
    /// the date-based default, so a hardcoded "Meeting" stem would diverge
    /// from the library and confuse users hunting for a specific meeting.
    /// For uncalendared meetings the displayName is "Meeting <date>" and
    /// the filename ends up with the date twice (once from the date prefix,
    /// once from the stem) — slightly redundant, but matches the library
    /// label exactly, which is what users expect to grep for.
    func buildFileURL(for transcription: Transcription, format: AutoSaveFormat, in folder: URL) -> URL {
        let stem = TranscriptSegmenter.sanitizedExportStem(from: transcription.fileName)
        let dateStr = Self.dateFormatter.string(from: transcription.createdAt)
        let baseName = "\(dateStr)-\(stem)"

        var fileURL = folder.appendingPathComponent("\(baseName).\(format.fileExtension)")

        // Deduplicate if file already exists
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = folder.appendingPathComponent("\(baseName) (\(counter)).\(format.fileExtension)")
            counter += 1
        }

        return fileURL
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

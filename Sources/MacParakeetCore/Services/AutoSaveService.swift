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
/// Each scope stores its own enabled flag, format, and folder bookmark in UserDefaults.
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
    func buildFileURL(for transcription: Transcription, format: AutoSaveFormat, in folder: URL) -> URL {
        let stem: String
        if transcription.sourceType == .meeting {
            // Meeting display names already contain the date (e.g. "Meeting Apr 6, 2026 at 10:02 PM"),
            // so use just the title prefix to avoid date duplication in the filename.
            stem = "Meeting"
        } else {
            stem = TranscriptSegmenter.sanitizedExportStem(from: transcription.fileName)
        }
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

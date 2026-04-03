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

/// Automatically saves completed transcriptions to a user-chosen folder.
/// Reads configuration from UserDefaults; does nothing when auto-save is disabled
/// or no folder is configured.
@MainActor
public final class AutoSaveService {
    private let exportService: ExportServiceProtocol
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AutoSaveService")

    public static let enabledKey = "autoSaveTranscripts"
    public static let formatKey = "autoSaveFormat"
    public static let folderBookmarkKey = "autoSaveFolderBookmark"

    public init(
        exportService: ExportServiceProtocol? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.exportService = exportService ?? ExportService()
        self.defaults = defaults
    }

    /// Save the transcription if auto-save is enabled and a folder is configured.
    /// Failures are logged but never surfaced to the user.
    public func saveIfEnabled(_ transcription: Transcription) {
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        guard let folderURL = resolveFolder() else {
            logger.warning("Auto-save enabled but no valid folder configured.")
            return
        }

        let format = AutoSaveFormat(rawValue: defaults.string(forKey: Self.formatKey) ?? "md") ?? .md
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

            logger.info("Auto-saved transcript to \(fileURL.lastPathComponent)")
        } catch {
            logger.error("Auto-save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Folder Bookmark

    /// Resolve the stored bookmark data back to a URL.
    /// Re-creates the bookmark if it has gone stale.
    public func resolveFolder() -> URL? {
        guard let bookmarkData = defaults.data(forKey: Self.folderBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            if let refreshed = try? url.bookmarkData() {
                defaults.set(refreshed, forKey: Self.folderBookmarkKey)
            }
        }
        return url
    }

    /// Store a folder URL as bookmark data. Returns the display path on success.
    @discardableResult
    public static func storeFolder(_ url: URL, defaults: UserDefaults = .standard) -> String? {
        guard let data = try? url.bookmarkData() else { return nil }
        defaults.set(data, forKey: folderBookmarkKey)
        return url.path
    }

    /// Clear the stored folder bookmark.
    public static func clearFolder(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: folderBookmarkKey)
    }

    // MARK: - Filename

    /// Build a deduplicated file URL for the given transcription.
    /// Format: `YYYY-MM-DD-HHmmss-<sanitized-name>.<ext>`
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

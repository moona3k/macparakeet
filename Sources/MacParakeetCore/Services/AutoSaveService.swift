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

/// Outcome of attempting an automatic export.
public enum AutoSaveResult: Equatable, Sendable {
    case disabled
    case saved
    case folderUnavailable
    case failed
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
    public static let meetingIncludeTimestampsKey = "meetingAutoSaveIncludeTimestamps"
    public static let meetingIncludeSpeakerLabelsKey = "meetingAutoSaveIncludeSpeakerLabels"
    public static let meetingIncludeMetadataKey = "meetingAutoSaveIncludeMetadata"

    public init(
        exportService: ExportServiceProtocol? = nil,
        defaults: UserDefaults = .standard
    ) {
        Self.migrateLegacyMeetingSettingsIfNeeded(defaults: defaults)
        self.exportService = exportService ?? ExportService()
        self.defaults = defaults
    }

    /// Save the transcription if auto-save is enabled for the given scope.
    /// The result lets callers surface failures without making the primary
    /// transcription or meeting save fail.
    @discardableResult
    public func saveIfEnabled(
        _ transcription: Transcription,
        scope: AutoSaveScope = .transcription
    ) -> AutoSaveResult {
        guard defaults.bool(forKey: scope.enabledKey) else { return .disabled }
        let format = AutoSaveFormat(rawValue: defaults.string(forKey: scope.formatKey) ?? "md") ?? .md
        let textOptions = transcriptExportOptions(for: scope)
        let operationContext = Observability.childOperationContext()
        guard let folderURL = resolveFolder(scope: scope) else {
            logger.warning("Auto-save enabled but no valid folder configured for \(scope.rawValue).")
            sendAutoSaveOperation(
                operationContext: operationContext,
                scope: scope,
                format: format,
                outcome: .unavailable,
                errorType: "folder_unavailable"
            )
            return .folderUnavailable
        }

        let fileURL = buildFileURL(for: transcription, format: format, in: folderURL)

        do {
            // Ensure the folder still exists
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            switch format {
            case .txt:
                try exportService.exportToTxt(
                    transcription: transcription,
                    url: fileURL,
                    options: textOptions
                )
            case .md:
                try exportService.exportToMarkdown(
                    transcription: transcription,
                    url: fileURL,
                    options: textOptions
                )
            case .srt: try exportService.exportToSRT(transcription: transcription, url: fileURL)
            case .vtt: try exportService.exportToVTT(transcription: transcription, url: fileURL)
            case .json: try exportService.exportToJSON(transcription: transcription, url: fileURL)
            }

            logger.info("auto_save_completed scope=\(scope.rawValue, privacy: .public) format=\(format.rawValue, privacy: .public) outcome=success")
            sendAutoSaveOperation(
                operationContext: operationContext,
                scope: scope,
                format: format,
                outcome: .success
            )
            return .saved
        } catch {
            let errorType = Observability.errorType(for: error)
            logger.error("auto_save_failed scope=\(scope.rawValue, privacy: .public) format=\(format.rawValue, privacy: .public) outcome=failure error_type=\(errorType, privacy: .public)")
            sendAutoSaveOperation(
                operationContext: operationContext,
                scope: scope,
                format: format,
                outcome: .failure,
                errorType: errorType
            )
            return .failed
        }
    }

    // MARK: - Folder Bookmark

    /// Resolve the stored bookmark data back to a URL for the given scope.
    /// Re-creates the bookmark if it has gone stale.
    public func resolveFolder(scope: AutoSaveScope = .transcription) -> URL? {
        Self.resolveFolder(scope: scope, defaults: defaults)
    }

    /// Resolve the stored bookmark data back to a URL for the given scope.
    /// Re-creates the bookmark if it has gone stale.
    public nonisolated static func resolveFolder(
        scope: AutoSaveScope = .transcription,
        defaults: UserDefaults = .standard
    ) -> URL? {
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

    /// Resolve captured bookmark data without changing the stored bookmark.
    /// This is useful for asynchronous preflight work whose result may become
    /// stale while the user chooses a different folder.
    public nonisolated static func resolveFolder(bookmarkData: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            bookmarkDataIsStale: &isStale
        )
    }

    /// A non-invasive preflight for Settings. The real export remains the
    /// authoritative write check because availability can change at any time.
    public nonisolated static func isFolderUsable(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return false
            }
            return FileManager.default.isWritableFile(atPath: url.path)
        }.value
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

    private func transcriptExportOptions(for scope: AutoSaveScope) -> TranscriptExportOptions {
        guard scope == .meeting else { return .default }
        return TranscriptExportOptions(
            includeTimestamps: bool(defaultingToTrueForKey: Self.meetingIncludeTimestampsKey),
            includeSpeakerLabels: bool(defaultingToTrueForKey: Self.meetingIncludeSpeakerLabelsKey),
            includeMetadata: bool(defaultingToTrueForKey: Self.meetingIncludeMetadataKey)
        )
    }

    private func bool(defaultingToTrueForKey key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    private func sendAutoSaveOperation(
        operationContext: ObservabilityOperationContext,
        scope: AutoSaveScope,
        format: AutoSaveFormat,
        outcome: ObservabilityOutcome,
        errorType: String? = nil
    ) {
        Telemetry.send(.autoSaveOperation(
            operationID: operationContext.operationID,
            operationContext: operationContext,
            scope: scope,
            format: format,
            outcome: outcome,
            durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
            errorType: errorType
        ))
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

    /// The default destination for auto-saved files when the user hasn't
    /// chosen one. Lives under `~/Documents/MacParakeet/{Transcriptions|Meetings}`
    /// so the user can find their output via Finder / Spotlight without
    /// digging into `~/Library`.
    public static func defaultFolder(for scope: AutoSaveScope) -> URL {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let parent = docs.appendingPathComponent("MacParakeet", isDirectory: true)
        switch scope {
        case .transcription: return parent.appendingPathComponent("Transcriptions", isDirectory: true)
        case .meeting: return parent.appendingPathComponent("Meetings", isDirectory: true)
        }
    }

    /// Ensure the auto-save folder is configured for `scope`. Idempotent:
    ///
    /// - If a bookmark is already stored (even one that fails to resolve right
    ///   now, e.g. a disconnected external drive) it is left untouched —
    ///   never overwrite a user-chosen destination.
    /// - If no bookmark exists, create the default folder on disk and store
    ///   its bookmark.
    ///
    /// Returns the resolved folder URL on success, or `nil` if no bookmark
    /// was stored and the default folder couldn't be created or bookmarked (extremely
    /// rare — disk full, `~/Documents` read-only, etc.).
    @discardableResult
    public static func ensureFolderConfigured(scope: AutoSaveScope, defaults: UserDefaults = .standard) -> URL? {
        if defaults.data(forKey: scope.folderBookmarkKey) != nil {
            // Bookmark exists — preserve it even if stale / currently
            // unresolvable. The user's previously-chosen destination is
            // sacred; don't stomp it with a default.
            return resolveFolder(scope: scope, defaults: defaults)
        }
        let defaultURL = defaultFolder(for: scope)
        do {
            try FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)
            guard storeFolder(defaultURL, scope: scope, defaults: defaults) != nil else {
                return nil
            }
            return defaultURL
        } catch {
            return nil
        }
    }

    /// Explicit reset to the default folder. Unlike `ensureFolderConfigured`,
    /// this overwrites any existing bookmark — used by the "Reset" button so
    /// the user can deliberately revert to default after picking a custom
    /// destination.
    @discardableResult
    public static func resetFolderToDefault(scope: AutoSaveScope = .transcription, defaults: UserDefaults = .standard) -> URL? {
        let defaultURL = defaultFolder(for: scope)
        do {
            try FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)
            guard storeFolder(defaultURL, scope: scope, defaults: defaults) != nil else {
                return nil
            }
            return defaultURL
        } catch {
            return nil
        }
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

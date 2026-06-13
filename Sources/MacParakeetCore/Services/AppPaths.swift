import Foundation

/// Centralized path management for MacParakeet runtime files.
public enum AppPaths {
    public static let preferencesSuiteName = "com.macparakeet.MacParakeet"
    public static let meetingArtifactsFolderKey = "meetingArtifactsFolder"

    /// Application Support directory
    public static var appSupportDir: String {
        let path = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return path + "/MacParakeet"
    }

    /// Database file path
    public static var databasePath: String {
        "\(appSupportDir)/macparakeet.db"
    }

    /// Audio storage directory for dictations
    public static var dictationsDir: String {
        "\(appSupportDir)/dictations"
    }

    /// Audio storage directory for downloaded YouTube transcription audio
    public static var youtubeDownloadsDir: String {
        "\(appSupportDir)/youtube-downloads"
    }

    /// Default audio/artifact storage directory for meeting recordings.
    public static var defaultMeetingRecordingsDir: String {
        "\(appSupportDir)/meeting-recordings"
    }

    /// Audio/artifact storage directory for meeting recordings.
    public static var meetingRecordingsDir: String {
        configuredMeetingRecordingsDir()
    }

    public static func configuredMeetingRecordingsDir(defaults: UserDefaults = .standard) -> String {
        if let raw = defaults.string(forKey: meetingArtifactsFolderKey),
           let path = normalizedMeetingArtifactsFolder(raw) {
            return path
        }
        return defaultMeetingRecordingsDir
    }

    public static func sharedAppDefaults() -> UserDefaults {
        UserDefaults(suiteName: preferencesSuiteName) ?? .standard
    }

    public static func normalizedMeetingArtifactsFolder(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Local diagnostic logs directory.
    public static var logsDir: String {
        let path = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .path
            ?? (NSHomeDirectory() + "/Library")
        return path + "/Logs/MacParakeet"
    }

    /// Directory for managed helper binaries (e.g. yt-dlp).
    public static var binDir: String {
        "\(appSupportDir)/bin"
    }

    /// WhisperKit CoreML model cache base.
    public static var whisperModelsDir: String {
        "\(appSupportDir)/models/stt/whisper"
    }

    /// Managed yt-dlp binary path.
    public static var ytDlpBinaryPath: String {
        "\(binDir)/yt-dlp"
    }

    /// Resolve bundled yt-dlp seed binary from app resources.
    /// Returns nil when running outside an app bundle or when yt-dlp is not present.
    public static func bundledYtDlpPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let ytDlpPath = (resourcePath as NSString).appendingPathComponent("yt-dlp")
        return FileManager.default.isExecutableFile(atPath: ytDlpPath) ? ytDlpPath : nil
    }

    /// Cached discover feed
    public static var discoverCachePath: String {
        "\(appSupportDir)/discover-cache.json"
    }

    /// Thumbnail cache directory
    public static var thumbnailsDir: String {
        "\(appSupportDir)/thumbnails"
    }

    /// Temp directory for audio processing
    public static var tempDir: String {
        "\(NSTemporaryDirectory())macparakeet"
    }

    /// Ensure all required directories exist
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupportDir, dictationsDir, youtubeDownloadsDir, meetingRecordingsDir, binDir, whisperModelsDir, thumbnailsDir, logsDir, tempDir] {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// Resolve bundled FFmpeg binary path from app resources.
    /// Returns nil when running outside an app bundle or when ffmpeg is not present.
    public static func bundledFFmpegPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let ffmpegPath = (resourcePath as NSString).appendingPathComponent("ffmpeg")
        return FileManager.default.isExecutableFile(atPath: ffmpegPath) ? ffmpegPath : nil
    }
}

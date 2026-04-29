import Foundation

/// Centralized path management for MacParakeet runtime files.
public enum AppPaths {
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

    /// Audio storage directory for meeting recordings
    public static var meetingRecordingsDir: String {
        "\(appSupportDir)/meeting-recordings"
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

    /// Root for the cleanup CLI's managed Python runtime. The "Install Python
    /// dependencies" Settings button populates `site-packages` here; the
    /// launcher script picks it up via $PYTHONPATH.
    public static var cleanupRuntimeDir: String {
        "\(appSupportDir)/cleanup-runtime"
    }

    /// site-packages directory inside the managed cleanup runtime.
    public static var cleanupRuntimeSitePackagesDir: String {
        "\(cleanupRuntimeDir)/site-packages"
    }

    /// Sentinel file marking a successful dep install. The trailing version
    /// lets us invalidate when we bump pinned requirements without leaving
    /// half-installed wheels around.
    public static func cleanupRuntimeReadyMarker(version: Int) -> String {
        "\(cleanupRuntimeDir)/.ready-v\(version)"
    }

    /// Hugging Face cache root used by the cleanup daemon. Cleanup launchers
    /// export `HF_HOME` to this path so model downloads land predictably.
    public static var llmModelsHFHome: String {
        "\(appSupportDir)/models/llm"
    }

    /// Resolve the bundled `cleanup/requirements.txt` from app resources.
    public static func bundledCleanupRequirementsPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString)
            .appendingPathComponent("cleanup/requirements.txt")
        return FileManager.default.fileExists(atPath: path) ? path : nil
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
        for dir in [appSupportDir, dictationsDir, youtubeDownloadsDir, meetingRecordingsDir, binDir, whisperModelsDir, thumbnailsDir, tempDir] {
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

    /// Resolve bundled `macparakeet-cleanup` launcher from app resources.
    /// Looks for `Contents/Resources/cleanup/bin/macparakeet-cleanup` (the launcher
    /// script needs the surrounding `cleanup/` layout to find its `.venv` and
    /// Python module). Returns nil when running outside an app bundle or when the
    /// cleanup tree is not present.
    public static func bundledCleanupCLIPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let cliPath = (resourcePath as NSString)
            .appendingPathComponent("cleanup/bin/macparakeet-cleanup")
        return FileManager.default.isExecutableFile(atPath: cliPath) ? cliPath : nil
    }
}

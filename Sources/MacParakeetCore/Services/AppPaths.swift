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

    /// Directory for managed helper binaries (e.g. yt-dlp).
    public static var binDir: String {
        "\(appSupportDir)/bin"
    }

    /// Managed yt-dlp binary path.
    public static var ytDlpBinaryPath: String {
        "\(binDir)/yt-dlp"
    }

    /// Temp directory for audio processing
    public static var tempDir: String {
        "\(NSTemporaryDirectory())macparakeet"
    }

    /// Ensure all required directories exist
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupportDir, dictationsDir, youtubeDownloadsDir, binDir, tempDir] {
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

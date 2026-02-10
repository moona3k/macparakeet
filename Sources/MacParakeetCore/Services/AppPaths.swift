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

    /// Python venv directory
    public static var pythonVenvDir: String {
        "\(appSupportDir)/python"
    }

    /// Temp directory for audio processing
    public static var tempDir: String {
        "\(NSTemporaryDirectory())macparakeet"
    }

    /// Ensure all required directories exist
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupportDir, dictationsDir, tempDir] {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }
}

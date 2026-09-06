import FluidAudio
import Foundation

/// Centralized path management for MacParakeet runtime files.
public enum AppPaths {
    public static let preferencesSuiteName = "com.macparakeet.MacParakeet"
    public static let meetingArtifactsFolderKey = "meetingArtifactsFolder"
    #if DEBUG
    public static let debugAppStateDirEnvironmentKey = "MACPARAKEET_DEBUG_APP_STATE_DIR"
    #endif

    /// Application Support directory
    public static var appSupportDir: String {
        resolvedAppSupportDir(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedAppSupportDir(environment: [String: String]) -> String {
        #if DEBUG
        if let override = debugAppStateDir(environment: environment) {
            return override
        }
        #endif
        let path =
            FileManager.default
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

    static func defaultMeetingRecordingsDir(environment: [String: String]) -> String {
        "\(resolvedAppSupportDir(environment: environment))/meeting-recordings"
    }

    /// Audio/artifact storage directory for meeting recordings.
    public static var meetingRecordingsDir: String {
        configuredMeetingRecordingsDir()
    }

    public static func configuredMeetingRecordingsDir(defaults: UserDefaults = .standard) -> String {
        configuredMeetingRecordingsDir(
            defaults: defaults,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func configuredMeetingRecordingsDir(
        defaults: UserDefaults = .standard,
        environment: [String: String]
    ) -> String {
        #if DEBUG
        if debugAppStateDir(environment: environment) != nil {
            return defaultMeetingRecordingsDir(environment: environment)
        }
        #endif
        if let raw = defaults.string(forKey: meetingArtifactsFolderKey),
            let path = normalizedMeetingArtifactsFolder(raw)
        {
            return path
        }
        return defaultMeetingRecordingsDir(environment: environment)
    }

    /// Opens the named suite (falling back to `.standard` when the suite
    /// cannot be created), regardless of which process calls it. A
    /// process whose own bundle identifier equals `preferencesSuiteName`
    /// (the app itself, or a helper embedded in its bundle) reopening that
    /// domain as a named suite makes Foundation log a nonsensical-suite
    /// warning to stderr; such callers should read `appDefaults(bundleIdentifier:)`
    /// instead, which avoids that self-reopen.
    public static func sharedAppDefaults() -> UserDefaults {
        UserDefaults(suiteName: preferencesSuiteName) ?? .standard
    }

    /// Resolves the MacParakeet preferences domain the way a caller safely
    /// can from any process: `.standard` when the current process's own
    /// bundle identifier already is `preferencesSuiteName` (the running app,
    /// or an executable embedded in its `.app` bundle — both already read
    /// and write that domain as their own `.standard` defaults), and the
    /// named suite otherwise (a standalone binary such as the Homebrew CLI,
    /// whose own domain differs from the app's and therefore needs to open
    /// it explicitly to share preferences with the app).
    public static func appDefaults(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> UserDefaults {
        if bundleIdentifier == preferencesSuiteName {
            return .standard
        }
        return sharedAppDefaults()
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
        #if DEBUG
        if let override = debugAppStateDir(environment: ProcessInfo.processInfo.environment) {
            return "\(override)/logs"
        }
        #endif
        let path =
            FileManager.default
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

    /// Verified opt-in local LLM model cache.
    public static var llmModelsDir: String {
        "\(appSupportDir)/LLMModels"
    }

    /// FluidAudio model cache base.
    ///
    /// Production intentionally delegates to FluidAudio's own default resolver.
    /// Debug/test runs with `MACPARAKEET_DEBUG_APP_STATE_DIR` keep FluidAudio
    /// models inside the same throwaway state root as the rest of MacParakeet.
    public static var fluidAudioModelsDir: String {
        fluidAudioModelsDirURL.path
    }

    public static var fluidAudioModelsDirURL: URL {
        resolvedFluidAudioModelsDir(environment: ProcessInfo.processInfo.environment)
    }

    static var hasDebugAppStateDirOverride: Bool {
        hasDebugAppStateDirOverride(environment: ProcessInfo.processInfo.environment)
    }

    static func hasDebugAppStateDirOverride(environment: [String: String]) -> Bool {
        #if DEBUG
        debugAppStateDir(environment: environment) != nil
        #else
        false
        #endif
    }

    static var fluidAudioBaseDirURL: URL {
        fluidAudioModelsDirURL.deletingLastPathComponent()
    }

    static func fluidAudioModelDirectory(for repo: Repo) -> URL {
        fluidAudioModelsDirURL.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    static func fluidAudioModelDirectory(forASRVersion version: AsrModelVersion) -> URL {
        fluidAudioModelDirectory(for: fluidAudioRepo(forASRVersion: version))
    }

    static func resolvedFluidAudioModelsDir(environment: [String: String]) -> URL {
        #if DEBUG
        if let override = debugAppStateDir(environment: environment) {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("FluidAudio", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
                .standardizedFileURL
        }
        #endif
        return MLModelConfigurationUtils.defaultModelsDirectory()
    }

    static func resolvedFluidAudioModelDirectory(for repo: Repo, environment: [String: String]) -> URL {
        resolvedFluidAudioModelsDir(environment: environment)
            .appendingPathComponent(repo.folderName, isDirectory: true)
    }

    static func resolvedFluidAudioModelDirectory(
        forASRVersion version: AsrModelVersion,
        environment: [String: String]
    ) -> URL {
        resolvedFluidAudioModelDirectory(
            for: fluidAudioRepo(forASRVersion: version),
            environment: environment
        )
    }

    private static func fluidAudioRepo(forASRVersion version: AsrModelVersion) -> Repo {
        switch version {
        case .v2:
            return .parakeetV2
        case .v3:
            return .parakeetV3
        case .tdtCtc110m:
            return .parakeetTdtCtc110m
        case .tdtJa:
            return .parakeetJa
        }
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

    /// Runtime directories shared by initialization and non-mutating health checks.
    public static var requiredDirectories: [String] {
        [
            appSupportDir, dictationsDir, youtubeDownloadsDir, meetingRecordingsDir, binDir, whisperModelsDir,
            thumbnailsDir, logsDir, tempDir,
        ]
    }

    /// Ensure all required directories exist
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in requiredDirectories {
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

    #if DEBUG
    private static func debugAppStateDir(environment: [String: String]) -> String? {
        guard
            let raw = environment[debugAppStateDirEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else {
            fatalError("\(debugAppStateDirEnvironmentKey) must be an absolute path")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    #endif
}

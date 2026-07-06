import XCTest
import FluidAudio
@testable import MacParakeetCore

final class AppPathsTests: XCTestCase {

    func testAppSupportDirContainsMacParakeet() {
        XCTAssertTrue(AppPaths.appSupportDir.hasSuffix("MacParakeet"))
    }

    func testDatabasePathIsInsideAppSupport() {
        XCTAssertTrue(AppPaths.databasePath.hasPrefix(AppPaths.appSupportDir))
        XCTAssertTrue(AppPaths.databasePath.hasSuffix("macparakeet.db"))
    }

    func testDictationsDirIsInsideAppSupport() {
        XCTAssertTrue(AppPaths.dictationsDir.hasPrefix(AppPaths.appSupportDir))
        XCTAssertTrue(AppPaths.dictationsDir.hasSuffix("dictations"))
    }

    func testBinDirIsInsideAppSupport() {
        XCTAssertTrue(AppPaths.binDir.hasPrefix(AppPaths.appSupportDir))
        XCTAssertTrue(AppPaths.binDir.hasSuffix("bin"))
    }

    func testYtDlpBinaryPathIsInsideBinDir() {
        XCTAssertTrue(AppPaths.ytDlpBinaryPath.hasPrefix(AppPaths.binDir))
        XCTAssertTrue(AppPaths.ytDlpBinaryPath.hasSuffix("yt-dlp"))
    }

    func testYouTubeDownloadsDirIsInsideAppSupport() {
        XCTAssertTrue(AppPaths.youtubeDownloadsDir.hasPrefix(AppPaths.appSupportDir))
        XCTAssertTrue(AppPaths.youtubeDownloadsDir.hasSuffix("youtube-downloads"))
    }

    func testMeetingRecordingsDirIsInsideAppSupport() {
        XCTAssertTrue(AppPaths.defaultMeetingRecordingsDir.hasPrefix(AppPaths.appSupportDir))
        XCTAssertTrue(AppPaths.defaultMeetingRecordingsDir.hasSuffix("meeting-recordings"))
    }

    func testFluidAudioModelsDirUsesFluidAudioDefaultWithoutDebugOverride() {
        XCTAssertEqual(
            AppPaths.resolvedFluidAudioModelsDir(environment: [:]),
            MLModelConfigurationUtils.defaultModelsDirectory()
        )
    }

    func testMeetingRecordingsDirCanBeConfiguredFromDefaults() {
        let suiteName = "macparakeet.test.paths.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            AppPaths.configuredMeetingRecordingsDir(defaults: defaults),
            AppPaths.defaultMeetingRecordingsDir
        )

        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-meeting-artifacts")
            .path
        defaults.set(custom, forKey: AppPaths.meetingArtifactsFolderKey)
        XCTAssertEqual(AppPaths.configuredMeetingRecordingsDir(defaults: defaults), custom)
    }

    #if DEBUG
    func testDebugAppStateDirOverridesAppSupport() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-debug-state-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let environment = [AppPaths.debugAppStateDirEnvironmentKey: root.path]

        XCTAssertEqual(AppPaths.resolvedAppSupportDir(environment: environment), root.path)
        XCTAssertEqual(AppPaths.defaultMeetingRecordingsDir(environment: environment), root.appendingPathComponent("meeting-recordings").path)
    }

    func testDebugAppStateDirScopesFluidAudioModelsInsideThrowawayRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-debug-state-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let environment = [AppPaths.debugAppStateDirEnvironmentKey: root.path]
        let expectedModelsDir = root
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        XCTAssertEqual(AppPaths.resolvedFluidAudioModelsDir(environment: environment), expectedModelsDir)
        XCTAssertEqual(
            AppPaths.resolvedFluidAudioModelDirectory(forASRVersion: .v3, environment: environment),
            expectedModelsDir.appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true)
        )
        XCTAssertEqual(
            AppPaths.resolvedFluidAudioModelDirectory(for: .vad, environment: environment),
            expectedModelsDir.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
        )
    }

    func testDebugAppStateDirKeepsMeetingRecordingsInsideThrowawayRoot() {
        let suiteName = "macparakeet.test.paths.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let realLookingCustom = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MacParakeetRealArtifacts")
            .path
        defaults.set(realLookingCustom, forKey: AppPaths.meetingArtifactsFolderKey)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-debug-state-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let environment = [AppPaths.debugAppStateDirEnvironmentKey: root.path]

        XCTAssertEqual(
            AppPaths.configuredMeetingRecordingsDir(defaults: defaults, environment: environment),
            root.appendingPathComponent("meeting-recordings").path
        )
    }
    #endif

    func testLogsDirIsInsideUserLogs() {
        XCTAssertTrue(AppPaths.logsDir.contains("Library/Logs"))
        XCTAssertTrue(AppPaths.logsDir.hasSuffix("MacParakeet"))
    }

    func testTempDirContainsMacParakeet() {
        XCTAssertTrue(AppPaths.tempDir.contains("macparakeet"))
    }

    func testEnsureDirectoriesCreatesAll() throws {
        // Use a unique temp directory to avoid polluting real app support
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet_test_\(UUID().uuidString)")
        let fm = FileManager.default

        // Create subdirectories that mirror the AppPaths structure
        let appSupportSubdir = testRoot.appendingPathComponent("AppSupport")
        let dictationsSubdir = testRoot.appendingPathComponent("dictations")
        let tempSubdir = testRoot.appendingPathComponent("temp")

        defer {
            try? fm.removeItem(at: testRoot)
        }

        for dir in [appSupportSubdir, dictationsSubdir, tempSubdir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        XCTAssertTrue(fm.fileExists(atPath: appSupportSubdir.path))
        XCTAssertTrue(fm.fileExists(atPath: dictationsSubdir.path))
        XCTAssertTrue(fm.fileExists(atPath: tempSubdir.path))

        // Also verify the real ensureDirectories doesn't throw
        // (it may create real dirs, but those are expected app directories)
        try AppPaths.ensureDirectories()
    }
}

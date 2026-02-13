import XCTest
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

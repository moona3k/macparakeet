import XCTest
@testable import MacParakeetCore

final class CommandLineToolInstallServiceTests: XCTestCase {
    private var sandbox: URL!
    private var bundledToolURL: URL!
    private var installDirectory: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-install-\(UUID().uuidString)", isDirectory: true)
        bundledToolURL = sandbox.appendingPathComponent("MacParakeet.app/Contents/MacOS/macparakeet-cli")
        installDirectory = sandbox.appendingPathComponent("usr/local/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundledToolURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: bundledToolURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
    }

    func testCurrentStatusReportsNotInstalledWhenLinkIsMissing() async throws {
        let service = makeService()

        let status = await service.currentStatus()

        XCTAssertEqual(status, .notInstalled)
    }

    func testInstallCreatesSymlinkToBundledTool() async throws {
        let service = makeService()

        let status = try await service.install(overwriteExisting: false)
        let linkURL = installDirectory.appendingPathComponent("macparakeet-cli")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)

        XCTAssertEqual(status, .installed)
        XCTAssertEqual(destination, bundledToolURL.path)
    }

    func testCurrentStatusReportsInstalledForMatchingSymlink() async throws {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let linkURL = installDirectory.appendingPathComponent("macparakeet-cli")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: bundledToolURL.path)
        let service = makeService()

        let status = await service.currentStatus()

        XCTAssertEqual(status, .installed)
    }

    func testCurrentStatusReportsStaleSymlinkForDifferentTarget() async throws {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let otherTarget = sandbox.appendingPathComponent("Other.app/Contents/MacOS/macparakeet-cli")
        try FileManager.default.createDirectory(at: otherTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: otherTarget, atomically: true, encoding: .utf8)
        let linkURL = installDirectory.appendingPathComponent("macparakeet-cli")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: otherTarget.path)
        let service = makeService()

        let status = await service.currentStatus()

        XCTAssertEqual(status, .staleSymlink(currentTarget: otherTarget.path))
    }

    func testInstallRequiresOverwriteForStaleSymlink() async throws {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let otherTarget = sandbox.appendingPathComponent("Other.app/Contents/MacOS/macparakeet-cli")
        let linkURL = installDirectory.appendingPathComponent("macparakeet-cli")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: otherTarget.path)
        let service = makeService()

        do {
            _ = try await service.install(overwriteExisting: false)
            XCTFail("Expected stale symlink error")
        } catch let error as CommandLineToolInstallError {
            XCTAssertEqual(error, .staleSymlink(currentTarget: otherTarget.path))
        }
    }

    func testInstallCanOverwriteStaleSymlink() async throws {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let otherTarget = sandbox.appendingPathComponent("Other.app/Contents/MacOS/macparakeet-cli")
        let linkURL = installDirectory.appendingPathComponent("macparakeet-cli")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: otherTarget.path)
        let service = makeService()

        let status = try await service.install(overwriteExisting: true)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)

        XCTAssertEqual(status, .installed)
        XCTAssertEqual(destination, bundledToolURL.path)
    }

    func testCurrentStatusReportsPathConflictForNonSymlink() async throws {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let linkURL = installDirectory.appendingPathComponent("macparakeet-cli")
        try "not a link".write(to: linkURL, atomically: true, encoding: .utf8)
        let service = makeService()

        let status = await service.currentStatus()

        XCTAssertEqual(status, .pathConflict(path: linkURL.path))
    }

    func testInstallThrowsPathConflictForNonSymlink() async throws {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let linkURL = installDirectory.appendingPathComponent("macparakeet-cli")
        try "not a link".write(to: linkURL, atomically: true, encoding: .utf8)
        let service = makeService()

        do {
            _ = try await service.install(overwriteExisting: true)
            XCTFail("Expected path conflict")
        } catch let error as CommandLineToolInstallError {
            XCTAssertEqual(error, .pathConflict(path: linkURL.path))
        }
    }

    func testMissingBundledToolIsUnavailable() async throws {
        try FileManager.default.removeItem(at: bundledToolURL)
        let service = makeService()

        let status = await service.currentStatus()

        XCTAssertEqual(status, .unsupportedEnvironment("Bundled macparakeet-cli was not found."))
    }

    func testTranslocatedBundleIsUnavailable() async throws {
        let translocatedTool = sandbox
            .appendingPathComponent("AppTranslocation/123/d/MacParakeet.app/Contents/MacOS/macparakeet-cli")
        try FileManager.default.createDirectory(
            at: translocatedTool.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "tool".write(to: translocatedTool, atomically: true, encoding: .utf8)
        let service = CommandLineToolInstallService(
            bundledToolURL: translocatedTool,
            installDirectory: installDirectory
        )

        let status = await service.currentStatus()

        XCTAssertEqual(status, .unsupportedTranslocated)
    }

    private func makeService() -> CommandLineToolInstallService {
        CommandLineToolInstallService(
            bundledToolURL: bundledToolURL,
            installDirectory: installDirectory
        )
    }
}

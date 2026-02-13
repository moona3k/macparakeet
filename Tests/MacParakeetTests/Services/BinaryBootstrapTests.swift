import CryptoKit
import Foundation
import XCTest
@testable import MacParakeetCore

private final class MockBinaryBootstrapURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: BinaryBootstrapTestError.missingRequestHandler)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum BinaryBootstrapTestError: Error {
    case missingRequestHandler
}

final class BinaryBootstrapTests: XCTestCase {
    private var rootDir: URL!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("binary-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "BinaryBootstrapTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        MockBinaryBootstrapURLProtocol.requestHandler = nil

        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        if let rootDir {
            try? FileManager.default.removeItem(at: rootDir)
        }

        suiteName = nil
        rootDir = nil
        super.tearDown()
    }

    func testEnsureYtDlpAvailableDownloadsValidatesAndInstallsExecutable() async throws {
        let binaryData = Data("yt-dlp-test-binary".utf8)
        let checksum = sha256Hex(binaryData)

        let bootstrap = makeBootstrap { request in
            guard let url = request.url else {
                throw BinaryBootstrapError.downloadFailed("Missing URL")
            }

            switch url.lastPathComponent {
            case "yt-dlp_macos":
                return (Self.httpResponse(url: url, statusCode: 200), binaryData)
            case "SHA2-256SUMS":
                let checksums = "\(checksum) yt-dlp_macos\n"
                return (Self.httpResponse(url: url, statusCode: 200), Data(checksums.utf8))
            default:
                return (Self.httpResponse(url: url, statusCode: 404), Data())
            }
        }

        let installedPath = try await bootstrap.ensureYtDlpAvailable()
        XCTAssertEqual(installedPath, ytDlpPath.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedPath))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installedPath))
        XCTAssertEqual(try Data(contentsOf: ytDlpPath), binaryData)

        let attributes = try FileManager.default.attributesOfItem(atPath: installedPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o755)
        XCTAssertEqual(tempBinaryArtifactCount(), 0)
    }

    func testEnsureYtDlpAvailableChecksumMismatchRemovesTempBinary() async throws {
        let binaryData = Data("yt-dlp-test-binary".utf8)

        let bootstrap = makeBootstrap { request in
            guard let url = request.url else {
                throw BinaryBootstrapError.downloadFailed("Missing URL")
            }

            switch url.lastPathComponent {
            case "yt-dlp_macos":
                return (Self.httpResponse(url: url, statusCode: 200), binaryData)
            case "SHA2-256SUMS":
                let checksums = "deadbeef yt-dlp_macos\n"
                return (Self.httpResponse(url: url, statusCode: 200), Data(checksums.utf8))
            default:
                return (Self.httpResponse(url: url, statusCode: 404), Data())
            }
        }

        do {
            _ = try await bootstrap.ensureYtDlpAvailable()
            XCTFail("Expected checksum mismatch")
        } catch let error as BinaryBootstrapError {
            if case .checksumMismatch = error {
                // expected
            } else {
                XCTFail("Expected checksumMismatch, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: ytDlpPath.path))
        XCTAssertEqual(tempBinaryArtifactCount(), 0)
    }

    func testEnsureYtDlpAvailableDownloadHTTPErrorThrows() async throws {
        let bootstrap = makeBootstrap { request in
            guard let url = request.url else {
                throw BinaryBootstrapError.downloadFailed("Missing URL")
            }

            switch url.lastPathComponent {
            case "yt-dlp_macos":
                return (Self.httpResponse(url: url, statusCode: 503), Data())
            case "SHA2-256SUMS":
                return (Self.httpResponse(url: url, statusCode: 200), Data())
            default:
                return (Self.httpResponse(url: url, statusCode: 404), Data())
            }
        }

        do {
            _ = try await bootstrap.ensureYtDlpAvailable()
            XCTFail("Expected downloadFailed")
        } catch let error as BinaryBootstrapError {
            if case .downloadFailed = error {
                // expected
            } else {
                XCTFail("Expected downloadFailed, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: ytDlpPath.path))
        XCTAssertEqual(tempBinaryArtifactCount(), 0)
    }

    // MARK: - Helpers

    private var binDir: URL {
        rootDir.appendingPathComponent("bin", isDirectory: true)
    }

    private var tempDir: URL {
        rootDir.appendingPathComponent("tmp", isDirectory: true)
    }

    private var ytDlpPath: URL {
        binDir.appendingPathComponent("yt-dlp")
    }

    private func makeBootstrap(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> BinaryBootstrap {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBinaryBootstrapURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockBinaryBootstrapURLProtocol.requestHandler = handler

        let defaults = UserDefaults(suiteName: suiteName)!
        let binDir = self.binDir
        let tempDir = self.tempDir
        let ytDlpPath = self.ytDlpPath

        return BinaryBootstrap(
            session: session,
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            fileManager: .default,
            ensureDirectories: {
                try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            },
            ytDlpBinaryPath: { ytDlpPath.path },
            tempDirPath: { tempDir.path }
        )
    }

    private func tempBinaryArtifactCount() -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix("yt-dlp-") }.count
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

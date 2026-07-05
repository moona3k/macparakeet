import CryptoKit
import XCTest
@testable import MacParakeetCore

final class InProcessModelDownloaderTests: XCTestCase {
    func testVerifyDefaultModelAcceptsCompleteManifestAndRejectsCorruption() async throws {
        let fixture = try makeFixture()
        try writeFixtureFiles(fixture)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        _ = try await downloader.verifyDefaultModel()

        let corruptFile = fixture.directory.appendingPathComponent("config.json")
        try "corrupt".data(using: .utf8)!.write(to: corruptFile)

        do {
            _ = try await downloader.verifyDefaultModel()
            XCTFail("Expected checksum or size verification to fail")
        } catch {
            XCTAssertTrue(error is InProcessModelDownloaderError)
        }
    }

    func testDownloadRepairsCorruptFileAndVerifiesManifest() async throws {
        let fixture = try makeFixture()
        try writeFixtureFiles(fixture)
        let corruptFile = fixture.directory.appendingPathComponent("config.json")
        try Data("bad".utf8).write(to: corruptFile)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        _ = try await downloader.downloadDefaultModel()

        XCTAssertEqual(try Data(contentsOf: corruptFile), fixture.files["config.json"])
        _ = try await downloader.verifyDefaultModel()
    }

    func testDownloadResumesPartialFile() async throws {
        let fixture = try makeFixture(files: ["model.safetensors": Data("abcdef".utf8)])
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let partial = fixture.directory.appendingPathComponent(".model.safetensors.part")
        try Data("abc".utf8).write(to: partial)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        _ = try await downloader.downloadDefaultModel()

        let requests = await fixture.transport.requests()
        XCTAssertEqual(requests.first?.resumeOffset, 3)
        XCTAssertEqual(
            try Data(contentsOf: fixture.directory.appendingPathComponent("model.safetensors")),
            Data("abcdef".utf8)
        )
    }

    func testDeleteRemovesModelDirectory() async throws {
        let fixture = try makeFixture()
        try writeFixtureFiles(fixture)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        try await downloader.deleteDefaultModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    private func makeFixture(
        files: [String: Data] = [
            "config.json": Data("{\"model\":\"test\"}".utf8),
            "model.safetensors": Data("weights".utf8),
        ]
    ) throws -> DownloaderFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InProcessModelDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        let manifest = InProcessLocalModelManifest(
            modelID: "example/test-model",
            displayName: "Test Model",
            repositoryID: "example/test-model",
            revision: "main",
            files: files.keys.sorted().map { path in
                InProcessLocalModelFile(
                    path: path,
                    sizeBytes: UInt64(files[path]!.count),
                    sha256: sha256Hex(files[path]!)
                )
            }
        )
        let directory = InProcessLocalModelCatalog.modelDirectory(for: manifest.modelID, cacheRoot: root)
        let urlFiles = Dictionary(uniqueKeysWithValues: files.map { path, data in
            (
                URL(string: "https://huggingface.co/\(manifest.repositoryID)/resolve/\(manifest.revision)/\(path)")!,
                data
            )
        })
        return DownloaderFixture(
            root: root,
            directory: directory,
            manifest: manifest,
            files: files,
            transport: MockInProcessModelDownloadTransport(files: urlFiles)
        )
    }

    private func writeFixtureFiles(_ fixture: DownloaderFixture) throws {
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        for (path, data) in fixture.files {
            try data.write(to: fixture.directory.appendingPathComponent(path))
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DownloaderFixture {
    let root: URL
    let directory: URL
    let manifest: InProcessLocalModelManifest
    let files: [String: Data]
    let transport: MockInProcessModelDownloadTransport
}

private actor MockInProcessModelDownloadTransport: InProcessModelDownloadTransport {
    private let files: [URL: Data]
    private var capturedRequests: [InProcessModelDownloadRequest] = []

    init(files: [URL: Data]) {
        self.files = files
    }

    func download(
        _ request: InProcessModelDownloadRequest,
        to destination: URL,
        onBytesReceived: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        capturedRequests.append(request)
        guard let data = files[request.url] else {
            throw URLError(.badURL)
        }
        if !FileManager.default.fileExists(atPath: destination.path) || request.resumeOffset == 0 {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if request.resumeOffset > 0 {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }
        let remaining = data.dropFirst(Int(request.resumeOffset))
        handle.write(Data(remaining))
        onBytesReceived(UInt64(remaining.count))
    }

    func requests() -> [InProcessModelDownloadRequest] {
        capturedRequests
    }
}

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

    func testDownloadPromotesCompleteVerifiedPartialWithoutRedownloading() async throws {
        let fixture = try makeFixture(files: ["model.safetensors": Data("abcdef".utf8)])
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let partial = fixture.directory.appendingPathComponent(".model.safetensors.part")
        try Data("abcdef".utf8).write(to: partial)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        _ = try await downloader.downloadDefaultModel()

        let requests = await fixture.transport.requests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: fixture.directory.appendingPathComponent("model.safetensors")),
            Data("abcdef".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testProgressDoesNotOvercountWhenServerIgnoresResumeOffset() async throws {
        let fixture = try makeFixture(files: ["model.safetensors": Data("abcdef".utf8)])
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let partial = fixture.directory.appendingPathComponent(".model.safetensors.part")
        try Data("abc".utf8).write(to: partial)
        await fixture.transport.setIgnoresResumeOffset(true)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )
        let recorder = ProgressRecorder()

        _ = try await downloader.downloadDefaultModel { progress in
            await recorder.append(progress.completedBytes)
        }

        let recorded = await recorder.values()
        XCTAssertEqual(recorded, recorded.sorted(), "Progress moved backward: \(recorded)")
        XCTAssertFalse(
            recorded.contains(3), "Discarded resume offset should not be emitted before response: \(recorded)")
        XCTAssertTrue(recorded.allSatisfy { $0 <= 6 }, "Progress overcounted the file size: \(recorded)")
        XCTAssertEqual(
            try Data(contentsOf: fixture.directory.appendingPathComponent("model.safetensors")),
            Data("abcdef".utf8)
        )
    }

    func testHasDefaultModelArtifactsDetectsPartialFiles() async throws {
        let fixture = try makeFixture()
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        let beforeAnyFiles = await downloader.hasDefaultModelArtifacts()
        XCTAssertFalse(beforeAnyFiles)

        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let partial = fixture.directory.appendingPathComponent(".model.safetensors.part")
        try Data("abc".utf8).write(to: partial)

        let downloaded = await downloader.isDefaultModelDownloaded()
        XCTAssertFalse(downloaded)
        let withPartial = await downloader.hasDefaultModelArtifacts()
        XCTAssertTrue(withPartial)

        try await downloader.deleteDefaultModel()
        let afterDelete = await downloader.hasDefaultModelArtifacts()
        XCTAssertFalse(afterDelete)
    }

    func testRemainingDownloadBytesAccountsForPartialFiles() async throws {
        let fixture = try makeFixture(files: ["model.safetensors": Data("abcdef".utf8)])
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let partial = fixture.directory.appendingPathComponent(".model.safetensors.part")
        try Data("abc".utf8).write(to: partial)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        let remaining = try await downloader.remainingDefaultModelDownloadBytes()

        XCTAssertEqual(remaining, 3)
        let requests = await fixture.transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRemainingDownloadBytesSkipsVerifiedCompletePartialFile() async throws {
        let fixture = try makeFixture(files: ["model.safetensors": Data("abcdef".utf8)])
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let partial = fixture.directory.appendingPathComponent(".model.safetensors.part")
        try Data("abcdef".utf8).write(to: partial)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        let remaining = try await downloader.remainingDefaultModelDownloadBytes()

        XCTAssertEqual(remaining, 0)
        let requests = await fixture.transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRemainingDownloadBytesIsZeroForVerifiedManagedCache() async throws {
        let fixture = try makeFixture()
        try writeFixtureFiles(fixture)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        _ = try await downloader.verifyDefaultModel()

        let remaining = try await downloader.remainingDefaultModelDownloadBytes()
        XCTAssertEqual(remaining, 0)
    }

    func testDefaultModelCacheSizeCountsManagedFiles() async throws {
        let fixture = try makeFixture(files: [
            "config.json": Data(repeating: 0x01, count: 4),
            "model.safetensors": Data(repeating: 0x02, count: 6),
        ])
        try writeFixtureFiles(fixture)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        let size = await downloader.defaultModelCacheSizeBytes()

        XCTAssertEqual(size, 10)
    }

    func testDefaultModelCacheSizeSkipsManagedDirectorySymlink() async throws {
        let fixture = try makeFixture()
        let external = fixture.root.appendingPathComponent("external-target", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 0x03, count: 9).write(to: external.appendingPathComponent("outside.bin"))
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.directory,
            withDestinationURL: external
        )
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        let size = await downloader.defaultModelCacheSizeBytes()

        XCTAssertEqual(size, 0)
    }

    func testCanceledDownloadThrowsCancellationAndPreservesCompletePartial() async throws {
        let fixture = try makeFixture(files: ["model.safetensors": Data("abcdef".utf8)])
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let partial = fixture.directory.appendingPathComponent(".model.safetensors.part")
        try Data("abcdef".utf8).write(to: partial)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        let task = Task {
            _ = try await downloader.downloadDefaultModel()
        }
        task.cancel()

        do {
            try await task.value
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let destination = fixture.directory.appendingPathComponent("model.safetensors")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partial.path)
                || FileManager.default.fileExists(atPath: destination.path)
        )
    }

    func testIsDefaultModelDownloadedRequiresVerificationMarkerAndRejectsSameSizeCorruption() async throws {
        let fixture = try makeFixture()
        try writeFixtureFiles(fixture)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        let downloaded = await downloader.isDefaultModelDownloaded()
        XCTAssertTrue(downloaded)

        let corruptFile = fixture.directory.appendingPathComponent("config.json")
        let originalModifiedAt =
            try FileManager.default
            .attributesOfItem(atPath: corruptFile.path)[.modificationDate] as? Date
        try Data(repeating: 0x78, count: fixture.files["config.json"]!.count).write(to: corruptFile)
        if let originalModifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: originalModifiedAt],
                ofItemAtPath: corruptFile.path
            )
        }
        let afterSameSizeCorruption = await downloader.isDefaultModelDownloaded()
        XCTAssertFalse(afterSameSizeCorruption)

        try writeFixtureFiles(fixture)
        _ = try await downloader.verifyDefaultModel()
        let managedDirectory = try InProcessLLMClient.managedModelDirectory(
            for: .inProcessLocal(model: fixture.manifest.modelID),
            manifest: fixture.manifest,
            cacheRoot: fixture.root
        )
        XCTAssertEqual(managedDirectory.standardizedFileURL, fixture.directory.standardizedFileURL)

        try FileManager.default.removeItem(
            at: fixture.directory.appendingPathComponent("config.json")
        )
        let afterRemoval = await downloader.isDefaultModelDownloaded()
        XCTAssertFalse(afterRemoval)
        XCTAssertThrowsError(
            try InProcessLLMClient.managedModelDirectory(
                for: .inProcessLocal(model: fixture.manifest.modelID),
                manifest: fixture.manifest,
                cacheRoot: fixture.root
            )
        )
    }

    func testDownloadRejectsManifestPathEscapingModelDirectory() async throws {
        let fixture = try makeFixture(files: ["../escape.bin": Data("escape".utf8)])
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        do {
            _ = try await downloader.downloadDefaultModel()
            XCTFail("Expected manifest path validation to reject directory traversal")
        } catch InProcessModelDownloaderError.invalidManifestPath("../escape.bin") {
            // Expected.
        } catch {
            XCTFail("Expected invalidManifestPath, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape.bin").path))
    }

    func testRedirectPolicyAllowsOnlyTrustedHTTPSHosts() {
        XCTAssertTrue(
            URLSessionInProcessModelDownloadTransport.isAllowedRedirectURL(
                URL(string: "https://huggingface.co/example/model")!
            ))
        XCTAssertTrue(
            URLSessionInProcessModelDownloadTransport.isAllowedRedirectURL(
                URL(string: "https://cdn-lfs.huggingface.co/example/model")!
            ))
        XCTAssertTrue(
            URLSessionInProcessModelDownloadTransport.isAllowedRedirectURL(
                URL(string: "https://cas-bridge.xethub.hf.co/example/model")!
            ))
        XCTAssertFalse(
            URLSessionInProcessModelDownloadTransport.isAllowedRedirectURL(
                URL(string: "http://huggingface.co/example/model")!
            ))
        XCTAssertFalse(
            URLSessionInProcessModelDownloadTransport.isAllowedRedirectURL(
                URL(string: "https://example.com/example/model")!
            ))
    }

    func testDeleteRemovesModelDirectory() async throws {
        let fixture = try makeFixture()
        try writeFixtureFiles(fixture)
        let sibling = fixture.root.appendingPathComponent("sibling.txt")
        try Data("keep".utf8).write(to: sibling)
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        try await downloader.deleteDefaultModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testDeleteRemovesManagedDirectorySymlinkWithoutFollowingIt() async throws {
        let fixture = try makeFixture()
        let external = fixture.root.appendingPathComponent("external-target", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: externalFile)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.directory,
            withDestinationURL: external
        )
        let downloader = InProcessModelDownloader(
            manifest: fixture.manifest,
            cacheRoot: fixture.root,
            transport: fixture.transport
        )

        try await downloader.deleteDefaultModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))
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
        let urlFiles = Dictionary(
            uniqueKeysWithValues: files.map { path, data in
                (
                    URL(
                        string: "https://huggingface.co/\(manifest.repositoryID)/resolve/\(manifest.revision)/\(path)")!,
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

private actor ProgressRecorder {
    private var recorded: [UInt64] = []

    func append(_ value: UInt64) {
        recorded.append(value)
    }

    func values() -> [UInt64] {
        recorded
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
    private var ignoresResumeOffset = false

    init(files: [URL: Data]) {
        self.files = files
    }

    func setIgnoresResumeOffset(_ value: Bool) {
        ignoresResumeOffset = value
    }

    func download(
        _ request: InProcessModelDownloadRequest,
        to destination: URL,
        onTotalBytesWritten: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        capturedRequests.append(request)
        guard let data = files[request.url] else {
            throw URLError(.badURL)
        }
        let effectiveOffset = ignoresResumeOffset ? 0 : request.resumeOffset
        if !FileManager.default.fileExists(atPath: destination.path) || effectiveOffset == 0 {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if effectiveOffset > 0 {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }
        var totalBytesWritten = effectiveOffset
        let remaining = Data(data.dropFirst(Int(effectiveOffset)))
        for chunkStart in stride(from: 0, to: remaining.count, by: 2) {
            let chunk = remaining[chunkStart..<min(chunkStart + 2, remaining.count)]
            try handle.write(contentsOf: chunk)
            totalBytesWritten += UInt64(chunk.count)
            onTotalBytesWritten(totalBytesWritten)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func requests() -> [InProcessModelDownloadRequest] {
        capturedRequests
    }
}

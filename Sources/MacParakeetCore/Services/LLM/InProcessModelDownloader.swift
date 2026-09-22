import CryptoKit
import Darwin
import Foundation

public struct InProcessLocalModelFile: Sendable, Equatable {
    public let path: String
    public let sizeBytes: UInt64
    public let sha256: String

    public init(path: String, sizeBytes: UInt64, sha256: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256.lowercased()
    }
}

public struct InProcessLocalModelManifest: Sendable, Equatable {
    public let modelID: String
    public let displayName: String
    public let repositoryID: String
    public let revision: String
    public let files: [InProcessLocalModelFile]

    public var totalBytes: UInt64 {
        files.reduce(0) { $0 + $1.sizeBytes }
    }
}

public struct InProcessModelDownloadProgress: Sendable, Equatable {
    public let completedBytes: UInt64
    public let totalBytes: UInt64
    public let completedFiles: Int
    public let totalFiles: Int
    public let currentFile: String?

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

public struct InProcessModelDownloadRequest: Sendable, Equatable {
    public let url: URL
    public let resumeOffset: UInt64

    public init(url: URL, resumeOffset: UInt64) {
        self.url = url
        self.resumeOffset = resumeOffset
    }
}

public protocol InProcessModelDownloadTransport: Sendable {
    func download(
        _ request: InProcessModelDownloadRequest,
        to destination: URL,
        onTotalBytesWritten: @escaping @Sendable (UInt64) -> Void
    ) async throws
}

public typealias InProcessModelDownloadProgressHandler =
    @Sendable (InProcessModelDownloadProgress) async -> Void

public protocol InProcessModelDownloading: Sendable {
    func defaultModelDirectory() -> URL
    func isDefaultModelDownloaded() async -> Bool
    func hasDefaultModelArtifacts() async -> Bool
    func defaultModelCacheSizeBytes() async -> UInt64
    func remainingDefaultModelDownloadBytes() async throws -> UInt64
    func verifyDefaultModel() async throws -> URL
    func downloadDefaultModel(progress: @escaping InProcessModelDownloadProgressHandler) async throws -> URL
    func deleteDefaultModel() async throws
}

public extension InProcessModelDownloading {
    func defaultModelCacheSizeBytes() async -> UInt64 { 0 }

    func remainingDefaultModelDownloadBytes() async throws -> UInt64 {
        InProcessLocalModelCatalog.defaultManifest.totalBytes
    }
}

public enum InProcessModelDownloaderError: LocalizedError, Equatable {
    case missingFile(String)
    case sizeMismatch(file: String, expected: UInt64, actual: UInt64)
    case checksumMismatch(file: String, expected: String, actual: String)
    case invalidHTTPStatus(Int)
    case invalidManifestPath(String)
    case manifestPathEscapesCache(String)
    case symlinkedManifestPath(String)
    case invalidVerificationMarker
    case disallowedRedirect(String)
    case fileCreationFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let file):
            return "Missing local AI model file: \(file)"
        case .sizeMismatch(let file, let expected, let actual):
            return "Local AI model file \(file) has size \(actual), expected \(expected)."
        case .checksumMismatch(let file, _, _):
            return "Local AI model file \(file) failed checksum verification."
        case .invalidHTTPStatus(let status):
            return "Model download failed with HTTP \(status)."
        case .invalidManifestPath(let path):
            return "Local AI model manifest path is not a safe relative path: \(path)"
        case .manifestPathEscapesCache(let path):
            return "Local AI model manifest path escapes the model cache: \(path)"
        case .symlinkedManifestPath(let path):
            return "Local AI model cache path uses a symbolic link: \(path)"
        case .invalidVerificationMarker:
            return "Local AI model verification marker is missing or stale."
        case .disallowedRedirect(let url):
            return "Model download redirected to an untrusted URL: \(url)"
        case .fileCreationFailed(let path, let code):
            return "Could not create local AI model cache file \(path) (errno \(code))."
        }
    }
}

public enum InProcessLocalModelCatalog {
    static let verificationMarkerFileName = ".macparakeet-verified-manifest.json"

    public static let defaultManifest = InProcessLocalModelManifest(
        modelID: "mlx-community/Qwen3-4B-Instruct-2507-DDWQ",
        displayName: "Qwen3 4B Instruct (DDWQ)",
        repositoryID: "mlx-community/Qwen3-4B-Instruct-2507-DDWQ",
        revision: "88033de44951ebedb96e0adb68cc037443aab93a",
        files: [
            InProcessLocalModelFile(
                path: "added_tokens.json",
                sizeBytes: 707,
                sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"
            ),
            InProcessLocalModelFile(
                path: "config.json",
                sizeBytes: 54_340,
                sha256: "d34791eee725047d963633517487093d28e9e0845f48d4f0e89c46fe3ff732dd"
            ),
            InProcessLocalModelFile(
                path: "generation_config.json",
                sizeBytes: 238,
                sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"
            ),
            InProcessLocalModelFile(
                path: "merges.txt",
                sizeBytes: 1_671_853,
                sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
            ),
            InProcessLocalModelFile(
                path: "model.safetensors",
                sizeBytes: 2_513_288_145,
                sha256: "93302f8b5d39da32ecc2b175472d5e31f6776ecfa813285833aa7470a24f3e5b"
            ),
            InProcessLocalModelFile(
                path: "model.safetensors.index.json",
                sizeBytes: 63_964,
                sha256: "2cd8d29f787f879bcda15972c72179b1d5800191cb957710a75b1cf6cf6c739c"
            ),
            InProcessLocalModelFile(
                path: "special_tokens_map.json",
                sizeBytes: 613,
                sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"
            ),
            InProcessLocalModelFile(
                path: "tokenizer.json",
                sizeBytes: 11_422_654,
                sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
            ),
            InProcessLocalModelFile(
                path: "tokenizer_config.json",
                sizeBytes: 9_627,
                sha256: "2f8396a75e4ef94389a2738b55a4d4aea47ca444f320c39f92f71c9c0a9c6ee8"
            ),
            InProcessLocalModelFile(
                path: "vocab.json",
                sizeBytes: 2_776_833,
                sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
            ),
        ]
    )

    public static func defaultCacheRoot() -> URL {
        URL(fileURLWithPath: AppPaths.llmModelsDir, isDirectory: true)
    }

    public static func modelDirectory(
        for modelID: String,
        cacheRoot: URL = defaultCacheRoot()
    ) -> URL {
        cacheRoot.appendingPathComponent(sanitizedDirectoryName(for: modelID), isDirectory: true)
    }

    public static func sanitizedDirectoryName(for modelID: String) -> String {
        modelID
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: ":", with: "_")
    }

    static func verifiedManagedCacheDirectory(
        for modelID: String,
        manifest: InProcessLocalModelManifest = defaultManifest,
        cacheRoot: URL = defaultCacheRoot(),
        fileManager: FileManager = .default
    ) throws -> URL {
        guard modelID == manifest.modelID else {
            throw LLMError.modelNotFound("Download the supported local AI model before using \(modelID).")
        }
        let directory = modelDirectory(for: modelID, cacheRoot: cacheRoot)
        guard try hasValidVerificationMarker(for: manifest, in: directory, fileManager: fileManager) else {
            throw LLMError.modelNotFound("Download and verify the local AI model before using \(modelID).")
        }
        return directory
    }

    static func fileURL(
        for file: InProcessLocalModelFile,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let components = try validatedManifestPathComponents(file.path)
        let base = directory.standardizedFileURL
        try assertNotSymlink(base)
        var candidate = base
        for component in components {
            candidate.appendPathComponent(component, isDirectory: false)
        }
        let standardized = candidate.standardizedFileURL
        guard isContained(standardized, in: base) else {
            throw InProcessModelDownloaderError.manifestPathEscapesCache(file.path)
        }
        try rejectSymlinkedExistingComponents(
            components,
            base: base,
            originalPath: file.path,
            fileManager: fileManager
        )
        return standardized
    }

    static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).part")
    }

    static func assertNotSymlink(_ url: URL) throws {
        guard isSymlink(at: url) else { return }
        throw InProcessModelDownloaderError.symlinkedManifestPath(url.path)
    }

    static func fileSize(at url: URL, fileManager: FileManager = .default) throws -> UInt64? {
        if isSymlink(at: url) {
            throw InProcessModelDownloaderError.symlinkedManifestPath(url.path)
        }
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }

    static func writeVerificationMarker(
        for manifest: InProcessLocalModelManifest,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let marker = try verificationMarker(for: manifest, in: directory, fileManager: fileManager)
        let data = try JSONEncoder().encode(marker)
        try data.write(to: verificationMarkerURL(in: directory), options: .atomic)
    }

    static func removeVerificationMarker(
        in directory: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: verificationMarkerURL(in: directory))
    }

    static func hasValidVerificationMarker(
        for manifest: InProcessLocalModelManifest,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let markerURL = verificationMarkerURL(in: directory)
        guard fileManager.fileExists(atPath: markerURL.path) else { return false }
        try assertNotSymlink(markerURL)
        let marker: VerificationMarker
        do {
            marker = try JSONDecoder().decode(VerificationMarker.self, from: Data(contentsOf: markerURL))
        } catch {
            removeVerificationMarker(in: directory, fileManager: fileManager)
            return false
        }
        let expected = try verificationMarker(for: manifest, in: directory, fileManager: fileManager)
        let isValid = marker == expected
        if !isValid {
            removeVerificationMarker(in: directory, fileManager: fileManager)
        }
        return isValid
    }

    static func manifestFingerprint(_ manifest: InProcessLocalModelManifest) -> String {
        var hasher = SHA256()
        update(&hasher, manifest.modelID)
        update(&hasher, manifest.repositoryID)
        update(&hasher, manifest.revision)
        for file in manifest.files.sorted(by: { $0.path < $1.path }) {
            update(&hasher, file.path)
            update(&hasher, String(file.sizeBytes))
            update(&hasher, file.sha256)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verificationMarkerURL(in directory: URL) -> URL {
        directory.appendingPathComponent(verificationMarkerFileName, isDirectory: false)
    }

    private static func verificationMarker(
        for manifest: InProcessLocalModelManifest,
        in directory: URL,
        fileManager: FileManager
    ) throws -> VerificationMarker {
        // The marker avoids re-hashing the 2.5 GB default model on every Settings refresh
        // or runtime load. It is written only after a full SHA-256 pass. The cheap path
        // trusts stable file metadata; if size, identity, modification time, or status-change
        // time changes, the marker is invalidated and callers must run full verification again.
        let files = try manifest.files.sorted(by: { $0.path < $1.path }).map { file in
            let url = try fileURL(for: file, in: directory, fileManager: fileManager)
            guard let size = try fileSize(at: url, fileManager: fileManager), size == file.sizeBytes else {
                throw InProcessModelDownloaderError.invalidVerificationMarker
            }
            let metadata = try fileMarkerMetadata(at: url)
            return VerificationMarker.FileEntry(
                path: file.path,
                sizeBytes: file.sizeBytes,
                sha256: file.sha256,
                modifiedAt: metadata.modifiedAt,
                changedAt: metadata.changedAt,
                deviceID: metadata.deviceID,
                inode: metadata.inode
            )
        }
        return VerificationMarker(
            version: 1,
            manifestFingerprint: manifestFingerprint(manifest),
            files: files
        )
    }

    private static func validatedManifestPathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
            throw InProcessModelDownloaderError.invalidManifestPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw InProcessModelDownloaderError.invalidManifestPath(path)
        }
        return components
    }

    private static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let basePath = directory.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func rejectSymlinkedExistingComponents(
        _ components: [String],
        base: URL,
        originalPath: String,
        fileManager: FileManager
    ) throws {
        var current = base
        for component in components {
            current.appendPathComponent(component, isDirectory: false)
            if isSymlink(at: current) {
                throw InProcessModelDownloaderError.symlinkedManifestPath(originalPath)
            }
            guard fileManager.fileExists(atPath: current.path) else { return }
        }
    }

    private static func isSymlink(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func fileMarkerMetadata(at url: URL) throws -> FileMarkerMetadata {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw InProcessModelDownloaderError.invalidVerificationMarker
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw InProcessModelDownloaderError.symlinkedManifestPath(url.path)
        }
        return FileMarkerMetadata(
            modifiedAt: timeInterval(info.st_mtimespec),
            changedAt: timeInterval(info.st_ctimespec),
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    private static func timeInterval(_ value: timespec) -> TimeInterval {
        TimeInterval(value.tv_sec) + (TimeInterval(value.tv_nsec) / 1_000_000_000)
    }

    private static func update(_ hasher: inout SHA256, _ string: String) {
        hasher.update(data: Data(string.utf8))
        hasher.update(data: Data([0]))
    }
}

private struct VerificationMarker: Codable, Equatable {
    struct FileEntry: Codable, Equatable {
        let path: String
        let sizeBytes: UInt64
        let sha256: String
        let modifiedAt: TimeInterval
        let changedAt: TimeInterval
        let deviceID: UInt64
        let inode: UInt64
    }

    let version: Int
    let manifestFingerprint: String
    let files: [FileEntry]
}

private struct FileMarkerMetadata {
    let modifiedAt: TimeInterval
    let changedAt: TimeInterval
    let deviceID: UInt64
    let inode: UInt64
}

public actor InProcessModelDownloader: InProcessModelDownloading {
    private let manifest: InProcessLocalModelManifest
    private let cacheRoot: URL
    private let transport: any InProcessModelDownloadTransport
    private let fileManager: FileManager

    public init(
        manifest: InProcessLocalModelManifest = InProcessLocalModelCatalog.defaultManifest,
        cacheRoot: URL = InProcessLocalModelCatalog.defaultCacheRoot(),
        transport: any InProcessModelDownloadTransport = URLSessionInProcessModelDownloadTransport(),
        fileManager: FileManager = .default
    ) {
        self.manifest = manifest
        self.cacheRoot = cacheRoot
        self.transport = transport
        self.fileManager = fileManager
    }

    public nonisolated func defaultModelDirectory() -> URL {
        InProcessLocalModelCatalog.modelDirectory(
            for: InProcessLocalModelCatalog.defaultManifest.modelID,
            cacheRoot: cacheRoot
        )
    }

    public func isDefaultModelDownloaded() async -> Bool {
        let directory = modelDirectory()
        do {
            if try InProcessLocalModelCatalog.hasValidVerificationMarker(
                for: manifest,
                in: directory,
                fileManager: fileManager
            ) {
                return true
            }
            _ = try await verifyDefaultModel()
            return true
        } catch {
            InProcessLocalModelCatalog.removeVerificationMarker(in: directory, fileManager: fileManager)
            return false
        }
    }

    public func hasDefaultModelArtifacts() async -> Bool {
        let contents = (try? fileManager.contentsOfDirectory(atPath: modelDirectory().path)) ?? []
        return !contents.isEmpty
    }

    public func defaultModelCacheSizeBytes() async -> UInt64 {
        directorySize(at: modelDirectory())
    }

    public func remainingDefaultModelDownloadBytes() async throws -> UInt64 {
        try Task.checkCancellation()
        let directory = modelDirectory()
        if try InProcessLocalModelCatalog.hasValidVerificationMarker(
            for: manifest,
            in: directory,
            fileManager: fileManager
        ) {
            return 0
        }

        var remaining: UInt64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            if try isFileVerified(file, in: directory) {
                continue
            }

            let destination = try InProcessLocalModelCatalog.fileURL(
                for: file,
                in: directory,
                fileManager: fileManager
            )
            let partial = InProcessLocalModelCatalog.partialURL(for: destination)
            let partialSize = try InProcessLocalModelCatalog.fileSize(at: partial, fileManager: fileManager) ?? 0
            if partialSize == file.sizeBytes, try isVerified(file: file, at: partial) {
                continue
            } else if partialSize > 0, partialSize < file.sizeBytes {
                remaining += file.sizeBytes - partialSize
            } else {
                remaining += file.sizeBytes
            }
        }
        return remaining
    }

    @discardableResult
    public func verifyDefaultModel() async throws -> URL {
        try Task.checkCancellation()
        let directory = modelDirectory()
        do {
            for file in manifest.files {
                try verify(file: file, in: directory)
            }
            try InProcessLocalModelCatalog.writeVerificationMarker(
                for: manifest,
                in: directory,
                fileManager: fileManager
            )
            return directory
        } catch {
            InProcessLocalModelCatalog.removeVerificationMarker(in: directory, fileManager: fileManager)
            throw error
        }
    }

    @discardableResult
    public func downloadDefaultModel(
        progress: @escaping InProcessModelDownloadProgressHandler = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let directory = modelDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var completedBytes: UInt64 = 0
        await progress(progressValue(completedBytes: completedBytes, completedFiles: 0))

        for (index, file) in manifest.files.enumerated() {
            try Task.checkCancellation()
            if try isFileVerified(file, in: directory) {
                completedBytes += file.sizeBytes
                await progress(
                    progressValue(
                        completedBytes: min(completedBytes, manifest.totalBytes),
                        completedFiles: index + 1
                    ))
                continue
            }

            let destination = try InProcessLocalModelCatalog.fileURL(
                for: file,
                in: directory,
                fileManager: fileManager
            )
            try await download(
                file: file, to: destination, completedBytesBeforeFile: completedBytes, progress: progress)
            completedBytes += file.sizeBytes
            await progress(
                progressValue(
                    completedBytes: min(completedBytes, manifest.totalBytes),
                    completedFiles: index + 1
                ))
        }

        try InProcessLocalModelCatalog.writeVerificationMarker(
            for: manifest,
            in: directory,
            fileManager: fileManager
        )
        return directory
    }

    public func deleteDefaultModel() async throws {
        try Task.checkCancellation()
        let directory = modelDirectory()
        try assertManagedModelDirectory(directory)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private nonisolated func modelDirectory() -> URL {
        InProcessLocalModelCatalog.modelDirectory(for: manifest.modelID, cacheRoot: cacheRoot)
    }

    private nonisolated func assertManagedModelDirectory(_ directory: URL) throws {
        let expectedName = InProcessLocalModelCatalog.sanitizedDirectoryName(for: manifest.modelID)
        guard directory.lastPathComponent == expectedName,
            directory.deletingLastPathComponent().path == cacheRoot.path
        else {
            throw InProcessModelDownloaderError.manifestPathEscapesCache(directory.path)
        }
    }

    private func directorySize(at url: URL) -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        var total: UInt64 = 0

        if let rootValues = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ) {
            if rootValues.isSymbolicLink == true {
                return 0
            }
            if rootValues.isRegularFile == true {
                return UInt64(max(0, rootValues.fileSize ?? 0))
            }
        }

        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        else {
            return 0
        }

        for case let childURL as URL in enumerator {
            guard
                let values = try? childURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                ),
                values.isSymbolicLink != true,
                values.isRegularFile == true
            else {
                continue
            }
            total += UInt64(max(0, values.fileSize ?? 0))
        }

        return total
    }

    private func download(
        file: InProcessLocalModelFile,
        to destination: URL,
        completedBytesBeforeFile: UInt64,
        progress: @escaping InProcessModelDownloadProgressHandler
    ) async throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try InProcessLocalModelCatalog.assertNotSymlink(destination.deletingLastPathComponent())
        try InProcessLocalModelCatalog.assertNotSymlink(destination)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        let partial = InProcessLocalModelCatalog.partialURL(for: destination)
        var attempts = 0
        while attempts < 2 {
            attempts += 1
            try Task.checkCancellation()
            let partialSize = try InProcessLocalModelCatalog.fileSize(at: partial, fileManager: fileManager) ?? 0
            if partialSize >= file.sizeBytes {
                if partialSize == file.sizeBytes, try isVerified(file: file, at: partial) {
                    try InProcessLocalModelCatalog.assertNotSymlink(destination.deletingLastPathComponent())
                    try InProcessLocalModelCatalog.assertNotSymlink(destination)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(at: partial, to: destination)
                    return
                }
                try? fileManager.removeItem(at: partial)
            }
            let effectiveResumeOffset =
                try InProcessLocalModelCatalog.fileSize(at: partial, fileManager: fileManager) ?? 0

            let (updates, updatesContinuation) = AsyncStream.makeStream(
                of: InProcessModelDownloadProgress.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let progressForwarder = Task {
                for await value in updates {
                    await progress(value)
                }
            }
            do {
                try await transport.download(
                    InProcessModelDownloadRequest(
                        url: downloadURL(for: file),
                        resumeOffset: effectiveResumeOffset
                    ),
                    to: partial
                ) { totalBytesWritten in
                    let fileBytes = min(totalBytesWritten, file.sizeBytes)
                    updatesContinuation.yield(
                        self.progressValue(
                            completedBytes: completedBytesBeforeFile + fileBytes,
                            completedFiles: self.completedFiles(before: file),
                            currentFile: file.path
                        ))
                }
                updatesContinuation.finish()
                await progressForwarder.value
            } catch {
                updatesContinuation.finish()
                progressForwarder.cancel()
                await progressForwarder.value
                try Task.checkCancellation()
                throw error
            }

            do {
                try verify(file: file, at: partial)
                try InProcessLocalModelCatalog.assertNotSymlink(destination.deletingLastPathComponent())
                try InProcessLocalModelCatalog.assertNotSymlink(destination)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: partial, to: destination)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? fileManager.removeItem(at: partial)
                if attempts >= 2 {
                    throw error
                }
            }
        }
    }

    private func verify(file: InProcessLocalModelFile, in directory: URL) throws {
        let url = try InProcessLocalModelCatalog.fileURL(for: file, in: directory, fileManager: fileManager)
        try verify(file: file, at: url)
    }

    private func verify(file: InProcessLocalModelFile, at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw InProcessModelDownloaderError.missingFile(file.path)
        }
        let actualSize = try InProcessLocalModelCatalog.fileSize(at: url, fileManager: fileManager) ?? 0
        guard actualSize == file.sizeBytes else {
            throw InProcessModelDownloaderError.sizeMismatch(
                file: file.path,
                expected: file.sizeBytes,
                actual: actualSize
            )
        }
        let actualHash = try sha256Hex(for: url)
        guard actualHash == file.sha256 else {
            throw InProcessModelDownloaderError.checksumMismatch(
                file: file.path,
                expected: file.sha256,
                actual: actualHash
            )
        }
    }

    private func isFileVerified(_ file: InProcessLocalModelFile, in directory: URL) throws -> Bool {
        let url = try InProcessLocalModelCatalog.fileURL(for: file, in: directory, fileManager: fileManager)
        return try isVerified(file: file, at: url)
    }

    private func isVerified(file: InProcessLocalModelFile, at url: URL) throws -> Bool {
        do {
            try verify(file: file, at: url)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private func downloadURL(for file: InProcessLocalModelFile) -> URL {
        let path = file.path
            .split(separator: "/")
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? String(component)
            }
            .joined(separator: "/")
        return URL(
            string: "https://huggingface.co/\(manifest.repositoryID)/resolve/\(manifest.revision)/\(path)"
        )!
    }

    private nonisolated func completedFiles(before file: InProcessLocalModelFile) -> Int {
        manifest.files.firstIndex(of: file) ?? 0
    }

    private nonisolated func progressValue(
        completedBytes: UInt64,
        completedFiles: Int,
        currentFile: String? = nil
    ) -> InProcessModelDownloadProgress {
        InProcessModelDownloadProgress(
            completedBytes: min(completedBytes, manifest.totalBytes),
            totalBytes: manifest.totalBytes,
            completedFiles: completedFiles,
            totalFiles: manifest.files.count,
            currentFile: currentFile
        )
    }

    private func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public final class URLSessionInProcessModelDownloadTransport: NSObject, InProcessModelDownloadTransport,
    @unchecked Sendable
{
    public override init() {}

    static func isAllowedRedirectURL(_ url: URL?) -> Bool {
        guard let url,
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased()
        else {
            return false
        }

        return host == "huggingface.co"
            || host.hasSuffix(".huggingface.co")
            || host == "hf.co"
            || host.hasSuffix(".hf.co")
    }

    public func download(
        _ request: InProcessModelDownloadRequest,
        to destination: URL,
        onTotalBytesWritten: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = 60
        if request.resumeOffset > 0 {
            urlRequest.setValue("bytes=\(request.resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let delegate = StreamingDownloadDelegate(
            destination: destination,
            requestedResumeOffset: request.resumeOffset,
            onTotalBytesWritten: onTotalBytesWritten
        )
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        let cancelBox = URLSessionTaskCancelBox(task: task)
        defer { session.invalidateAndCancel() }

        try await withTaskCancellationHandler {
            try await delegate.start(task: task)
        } onCancel: {
            cancelBox.cancel()
        }
    }
}

private final class URLSessionTaskCancelBox: @unchecked Sendable {
    private let task: URLSessionTask

    init(task: URLSessionTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let requestedResumeOffset: UInt64
    private let onTotalBytesWritten: @Sendable (UInt64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileHandle: FileHandle?
    private var totalBytesWritten: UInt64 = 0
    private var isCompleted = false

    init(
        destination: URL,
        requestedResumeOffset: UInt64,
        onTotalBytesWritten: @escaping @Sendable (UInt64) -> Void
    ) {
        self.destination = destination
        self.requestedResumeOffset = requestedResumeOffset
        self.onTotalBytesWritten = onTotalBytesWritten
    }

    func start(task: URLSessionDataTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            finish(throwing: InProcessModelDownloaderError.invalidHTTPStatus(-1))
            completionHandler(.cancel)
            return
        }
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            finish(throwing: InProcessModelDownloaderError.invalidHTTPStatus(httpResponse.statusCode))
            completionHandler(.cancel)
            return
        }

        do {
            let handle = try openDestinationFile(for: httpResponse)
            fileHandle = handle
            completionHandler(.allow)
        } catch {
            finish(throwing: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard URLSessionInProcessModelDownloadTransport.isAllowedRedirectURL(request.url) else {
            finish(throwing: InProcessModelDownloaderError.disallowedRedirect(request.url?.absoluteString ?? ""))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            totalBytesWritten += UInt64(data.count)
            onTotalBytesWritten(totalBytesWritten)
        } catch {
            finish(throwing: error)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        try? fileHandle?.close()
        fileHandle = nil
        if let error {
            finish(throwing: error)
        } else {
            finish(returning: ())
        }
    }

    private func finish(returning value: Void) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    private func finish(throwing error: Error) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        try? fileHandle?.close()
        continuation?.resume(throwing: error)
    }

    private func openDestinationFile(for httpResponse: HTTPURLResponse) throws -> FileHandle {
        try InProcessLocalModelCatalog.assertNotSymlink(destination.deletingLastPathComponent())
        try InProcessLocalModelCatalog.assertNotSymlink(destination)

        if requestedResumeOffset > 0, httpResponse.statusCode == 206 {
            let fileDescriptor = Darwin.open(destination.path, O_WRONLY | O_NOFOLLOW)
            guard fileDescriptor >= 0 else {
                throw InProcessModelDownloaderError.fileCreationFailed(path: destination.path, errno: errno)
            }
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
            let offset = try handle.seekToEnd()
            guard offset == requestedResumeOffset else {
                try? handle.close()
                throw InProcessModelDownloaderError.sizeMismatch(
                    file: destination.lastPathComponent,
                    expected: requestedResumeOffset,
                    actual: offset
                )
            }
            totalBytesWritten = requestedResumeOffset
            return handle
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let fileDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard fileDescriptor >= 0 else {
            throw InProcessModelDownloaderError.fileCreationFailed(path: destination.path, errno: errno)
        }
        totalBytesWritten = 0
        return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }
}

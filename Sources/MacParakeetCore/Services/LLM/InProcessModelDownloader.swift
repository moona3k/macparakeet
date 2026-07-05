import CryptoKit
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
        onBytesReceived: @escaping @Sendable (UInt64) -> Void
    ) async throws
}

public typealias InProcessModelDownloadProgressHandler =
    @Sendable (InProcessModelDownloadProgress) async -> Void

public protocol InProcessModelDownloading: Sendable {
    func defaultModelDirectory() -> URL
    func isDefaultModelDownloaded() async -> Bool
    func verifyDefaultModel() async throws -> URL
    func downloadDefaultModel(progress: @escaping InProcessModelDownloadProgressHandler) async throws -> URL
    func deleteDefaultModel() async throws
}

public enum InProcessModelDownloaderError: LocalizedError, Equatable {
    case missingFile(String)
    case sizeMismatch(file: String, expected: UInt64, actual: UInt64)
    case checksumMismatch(file: String, expected: String, actual: String)
    case invalidHTTPStatus(Int)

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
        }
    }
}

public enum InProcessLocalModelCatalog {
    public static let defaultManifest = InProcessLocalModelManifest(
        modelID: "mlx-community/Qwen3-4B-Instruct-2507-DDWQ",
        displayName: "Qwen3 4B Instruct (DDWQ)",
        repositoryID: "mlx-community/Qwen3-4B-Instruct-2507-DDWQ",
        revision: "main",
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
        (try? await verifyDefaultModel()) != nil
    }

    @discardableResult
    public func verifyDefaultModel() async throws -> URL {
        try Task.checkCancellation()
        let directory = modelDirectory()
        for file in manifest.files {
            try verify(file: file, in: directory)
        }
        return directory
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
            if isFileVerified(file, in: directory) {
                completedBytes += file.sizeBytes
                await progress(progressValue(
                    completedBytes: min(completedBytes, manifest.totalBytes),
                    completedFiles: index + 1
                ))
                continue
            }

            let destination = directory.appendingPathComponent(file.path)
            try await download(file: file, to: destination, completedBytesBeforeFile: completedBytes, progress: progress)
            completedBytes += file.sizeBytes
            await progress(progressValue(
                completedBytes: min(completedBytes, manifest.totalBytes),
                completedFiles: index + 1
            ))
        }

        return try await verifyDefaultModel()
    }

    public func deleteDefaultModel() async throws {
        try Task.checkCancellation()
        let directory = modelDirectory()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private nonisolated func modelDirectory() -> URL {
        InProcessLocalModelCatalog.modelDirectory(for: manifest.modelID, cacheRoot: cacheRoot)
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
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        let partial = partialURL(for: destination)
        var attempts = 0
        while attempts < 2 {
            attempts += 1
            try Task.checkCancellation()
            let resumeOffset = min(fileSize(at: partial) ?? 0, file.sizeBytes)
            if resumeOffset >= file.sizeBytes {
                try? fileManager.removeItem(at: partial)
            }
            let effectiveResumeOffset = fileSize(at: partial) ?? 0
            let accumulator = DownloadProgressAccumulator(initialBytes: effectiveResumeOffset)
            await progress(progressValue(
                completedBytes: completedBytesBeforeFile + effectiveResumeOffset,
                completedFiles: completedFiles(before: file),
                currentFile: file.path
            ))

            try await transport.download(
                InProcessModelDownloadRequest(
                    url: downloadURL(for: file),
                    resumeOffset: effectiveResumeOffset
                ),
                to: partial
            ) { delta in
                let fileBytes = min(accumulator.add(delta), file.sizeBytes)
                let progressValue = self.progressValue(
                    completedBytes: completedBytesBeforeFile + fileBytes,
                    completedFiles: self.completedFiles(before: file),
                    currentFile: file.path
                )
                Task {
                    await progress(progressValue)
                }
            }

            do {
                try verify(file: file, at: partial)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: partial, to: destination)
                return
            } catch {
                try? fileManager.removeItem(at: partial)
                if attempts >= 2 {
                    throw error
                }
            }
        }
    }

    private func verify(file: InProcessLocalModelFile, in directory: URL) throws {
        try verify(file: file, at: directory.appendingPathComponent(file.path))
    }

    private func verify(file: InProcessLocalModelFile, at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw InProcessModelDownloaderError.missingFile(file.path)
        }
        let actualSize = fileSize(at: url) ?? 0
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

    private func isFileVerified(_ file: InProcessLocalModelFile, in directory: URL) -> Bool {
        (try? verify(file: file, in: directory)) != nil
    }

    private func fileSize(at url: URL) -> UInt64? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }

    private func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).part")
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
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public final class URLSessionInProcessModelDownloadTransport: NSObject, InProcessModelDownloadTransport,
    @unchecked Sendable
{
    public override init() {}

    public func download(
        _ request: InProcessModelDownloadRequest,
        to destination: URL,
        onBytesReceived: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = 60
        if request.resumeOffset > 0 {
            urlRequest.setValue("bytes=\(request.resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let delegate = StreamingDownloadDelegate(
            destination: destination,
            requestedResumeOffset: request.resumeOffset,
            onBytesReceived: onBytesReceived
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

private final class DownloadProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64

    init(initialBytes: UInt64) {
        self.bytes = initialBytes
    }

    func add(_ delta: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        bytes += delta
        return bytes
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
    private let onBytesReceived: @Sendable (UInt64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileHandle: FileHandle?
    private var isCompleted = false

    init(
        destination: URL,
        requestedResumeOffset: UInt64,
        onBytesReceived: @escaping @Sendable (UInt64) -> Void
    ) {
        self.destination = destination
        self.requestedResumeOffset = requestedResumeOffset
        self.onBytesReceived = onBytesReceived
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
            if !FileManager.default.fileExists(atPath: destination.path) {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: destination)
            if requestedResumeOffset > 0, httpResponse.statusCode == 206 {
                try handle.seekToEnd()
            } else {
                try handle.truncate(atOffset: 0)
            }
            fileHandle = handle
            completionHandler(.allow)
        } catch {
            finish(throwing: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        fileHandle?.write(data)
        onBytesReceived(UInt64(data.count))
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
}

import Foundation
import CryptoKit

public actor VibeVoiceModelDownloader {

    public struct FileSpec: Sendable {
        public let remoteURL: URL
        public let localFilename: String
        public let expectedSizeBytes: Int64
        /// SHA-256 hex digest, lowercase. Verify after download; reject on mismatch.
        public let expectedSHA256: String

        public init(remoteURL: URL, localFilename: String, expectedSizeBytes: Int64, expectedSHA256: String) {
            self.remoteURL = remoteURL
            self.localFilename = localFilename
            self.expectedSizeBytes = expectedSizeBytes
            self.expectedSHA256 = expectedSHA256
        }
    }

    /// The 9.7 GB ASR model file. SHA-256 verified against the Phase 2.1
    /// spike download. If HuggingFace re-publishes a different blob, this
    /// hash needs updating (re-verify with `shasum -a 256`).
    public static let modelFile = FileSpec(
        remoteURL: URL(string: "https://huggingface.co/mudler/vibevoice.cpp-models/resolve/main/vibevoice-asr-q4_k.gguf")!,
        localFilename: "vibevoice-asr-q4_k.gguf",
        expectedSizeBytes: 10_392_063_296,
        expectedSHA256: "4eee48b9d0d42f71b773b804aa6728c99971c38d54f3c86cf1fd0fc1fc49a9ad"
    )

    /// The 5.6 MB Qwen-2.5 tokenizer file.
    public static let tokenizerFile = FileSpec(
        remoteURL: URL(string: "https://huggingface.co/mudler/vibevoice.cpp-models/resolve/main/tokenizer.gguf")!,
        localFilename: "tokenizer.gguf",
        expectedSizeBytes: 5_922_368,
        expectedSHA256: "37dc3b722d5677e37e29a57df55aa05c485116eeb5459e57ff8dde616b4986f6"
    )

    public static func defaultModelDirectory() -> URL {
        VibeVoiceEngine.defaultModelDirectory()
    }

    public static func areModelsInstalled(at dir: URL = defaultModelDirectory()) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(modelFile.localFilename).path)
            && fm.fileExists(atPath: dir.appendingPathComponent(tokenizerFile.localFilename).path)
    }

    // MARK: - Download

    public typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

    public enum DownloadError: Error, Equatable {
        case networkError(String)
        case writeError(String)
        case hashMismatch(expected: String, actual: String)
        case sizeMismatch(expected: Int64, actual: Int64)
        case cancelled
    }

    private let urlSession: URLSession
    private var currentTask: URLSessionDataTask?
    private var cancelled = false

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Downloads both files into `directory`, creating it if needed. Calls
    /// `onProgress` with cumulative bytes (across both files) and total expected.
    /// Pass `nil` for `directory` to use `defaultModelDirectory()`.
    public func downloadAll(
        to directory: URL? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws {
        let directory = directory ?? VibeVoiceModelDownloader.defaultModelDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let totalExpected = Self.modelFile.expectedSizeBytes + Self.tokenizerFile.expectedSizeBytes
        var cumulative: Int64 = 0

        // Tokenizer first — it's tiny and gives the user fast feedback.
        let tokOffset: Int64 = 0
        try await download(spec: Self.tokenizerFile, to: directory) { fileBytes in
            onProgress?(tokOffset + fileBytes, totalExpected)
        }
        cumulative += Self.tokenizerFile.expectedSizeBytes

        let modelOffset = cumulative
        try await download(spec: Self.modelFile, to: directory) { fileBytes in
            onProgress?(modelOffset + fileBytes, totalExpected)
        }
    }

    public func cancel() {
        cancelled = true
        currentTask?.cancel()
    }

    private func download(
        spec: FileSpec,
        to directory: URL,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let destination = directory.appendingPathComponent(spec.localFilename)
        let resumeFile = destination.appendingPathExtension("partial")

        // If a completed file already exists with the right hash, skip.
        if FileManager.default.fileExists(atPath: destination.path) {
            let hash = try Self.sha256(of: destination)
            if hash == spec.expectedSHA256 {
                onProgress(spec.expectedSizeBytes)
                return
            }
            // Stale, retry from scratch
            try FileManager.default.removeItem(at: destination)
        }

        // Resume if a partial exists
        let existingBytes: Int64 = (try? FileManager.default.attributesOfItem(atPath: resumeFile.path)[.size] as? Int64) ?? 0

        var request = URLRequest(url: spec.remoteURL)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        if cancelled { throw DownloadError.cancelled }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.networkError("Unexpected HTTP status")
        }

        // If we asked for a range resume but the server returned 200 (full file),
        // the existing partial-file bytes are stale — truncate before writing.
        // HuggingFace's CDN occasionally ignores Range headers and serves the full
        // file, which would otherwise produce a corrupted partial (existing prefix
        // + full re-download).
        var startingBytes = existingBytes
        if existingBytes > 0, httpResponse.statusCode == 200 {
            // Server ignored our Range header. Throw away the partial and start over.
            try? FileManager.default.removeItem(at: resumeFile)
            startingBytes = 0
        }

        // Append (or create) the partial file
        if !FileManager.default.fileExists(atPath: resumeFile.path) {
            FileManager.default.createFile(atPath: resumeFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: resumeFile)
        try handle.seekToEnd()
        defer { try? handle.close() }

        var receivedBytes: Int64 = startingBytes
        var buffer = Data()
        let chunkSize = 1 << 20  // 1 MB flushes — keeps memory bounded
        buffer.reserveCapacity(chunkSize)

        for try await byte in asyncBytes {
            if cancelled { throw DownloadError.cancelled }
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                onProgress(receivedBytes)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            receivedBytes += Int64(buffer.count)
            onProgress(receivedBytes)
        }
        try handle.close()

        // Size check
        let actualSize: Int64 = (try FileManager.default.attributesOfItem(atPath: resumeFile.path)[.size] as? Int64) ?? 0
        guard actualSize == spec.expectedSizeBytes else {
            try? FileManager.default.removeItem(at: resumeFile)
            throw DownloadError.sizeMismatch(expected: spec.expectedSizeBytes, actual: actualSize)
        }

        // Hash check
        let hash = try Self.sha256(of: resumeFile)
        guard hash == spec.expectedSHA256 else {
            try? FileManager.default.removeItem(at: resumeFile)
            throw DownloadError.hashMismatch(expected: spec.expectedSHA256, actual: hash)
        }

        // Promote the partial file to the final name
        try FileManager.default.moveItem(at: resumeFile, to: destination)
    }

    /// Streams SHA-256 over the file in chunks so a 10 GB file doesn't
    /// require loading into memory.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

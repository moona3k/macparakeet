import Foundation
import os

public enum PodcastAudioFetchError: Error, LocalizedError, Equatable {
    case invalidURL
    case requestFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The episode audio URL is not valid"
        case .requestFailed(let reason): return "Episode download failed: \(reason)"
        case .writeFailed(let reason): return "Could not save the episode audio: \(reason)"
        }
    }
}

public protocol PodcastAudioFetching: Sendable {
    /// Stream a podcast enclosure to a local file, reporting 0–100 progress
    /// (derived from `Content-Length` when the server provides it).
    func fetch(
        audioURL: String,
        suggestedName: String?,
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> URL
}

extension PodcastAudioFetching {
    public func fetch(audioURL: String, suggestedName: String?) async throws -> URL {
        try await fetch(audioURL: audioURL, suggestedName: suggestedName, onProgress: nil)
    }
}

/// Streams a podcast episode enclosure to disk with byte-progress reporting.
/// Swift port of `podcast-fetch`'s `download_episode`, backed by
/// `URLSessionDownloadTask` so the body streams to disk at native speed (no
/// per-byte async iteration) while `didWriteData` drives progress. URLSession
/// follows the tracking-prefix redirects podcast CDNs use; the file lands in the
/// shared app downloads directory so the existing retention + cleanup paths apply.
public actor PodcastAudioDownloader: PodcastAudioFetching {
    private static let knownAudioExtensions: Set<String> = [
        "mp3", "m4a", "mp4", "aac", "ogg", "oga", "opus", "wav", "flac", "wma", "webm", "aiff",
    ]
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "PodcastAudioDownloader")
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func fetch(
        audioURL: String,
        suggestedName: String?,
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> URL {
        let trimmed = audioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw PodcastAudioFetchError.invalidURL
        }

        let fm = FileManager.default
        let downloadsDir = AppPaths.youtubeDownloadsDir
        if !fm.fileExists(atPath: downloadsDir) {
            try fm.createDirectory(atPath: downloadsDir, withIntermediateDirectories: true)
        }

        var request = URLRequest(url: url)
        request.setValue("MacParakeet/1.0 (podcast-fetch)", forHTTPHeaderField: "User-Agent")

        // Download to a temporary file with native streaming; the delegate
        // reports progress and hands back the temp file + final response.
        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let taskBox = OSAllocatedUnfairLock<URLSessionDownloadTask?>(initialState: nil)
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.attach(continuation)
                    let task = session.downloadTask(with: request)
                    taskBox.withLock { $0 = task }
                    task.resume()
                }
            } onCancel: {
                taskBox.withLock { $0?.cancel() }
            }
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? fm.removeItem(at: tempURL)
            throw PodcastAudioFetchError.requestFailed("HTTP \(http.statusCode)")
        }

        let ext = Self.fileExtension(for: url, response: response)
        let outputURL = Self.uniqueOutputURL(
            in: URL(fileURLWithPath: downloadsDir, isDirectory: true),
            suggestedName: suggestedName,
            fileExtension: ext
        )
        do {
            if fm.fileExists(atPath: outputURL.path) {
                try fm.removeItem(at: outputURL)
            }
            try fm.moveItem(at: tempURL, to: outputURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw PodcastAudioFetchError.writeFailed(error.localizedDescription)
        }

        logger.info("podcast_audio_fetched")
        return outputURL
    }

    // MARK: - Helpers

    static func progressPercent(downloaded: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        let pct = (Double(downloaded) / Double(total)) * 100.0
        return max(0, min(Int(pct), 100))
    }

    static func fileExtension(for url: URL, response: URLResponse) -> String {
        let pathExt = url.pathExtension.lowercased()
        if knownAudioExtensions.contains(pathExt) {
            return pathExt
        }
        if let mime = response.mimeType?.lowercased() {
            if mime.contains("mpeg") || mime.contains("mp3") { return "mp3" }
            if mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") { return "m4a" }
            if mime.contains("ogg") || mime.contains("opus") { return "ogg" }
            if mime.contains("wav") { return "wav" }
        }
        return "mp3"
    }

    static func uniqueOutputURL(in directory: URL, suggestedName: String?, fileExtension: String) -> URL {
        let stem = sanitizedStem(suggestedName)
        let ext = fileExtension.isEmpty ? "mp3" : fileExtension
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(stem).\(ext)")
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    static func sanitizedStem(_ raw: String?) -> String {
        guard let raw else { return "Podcast Episode" }
        var disallowed = CharacterSet(charactersIn: "/:\\\"")
        disallowed.formUnion(.controlCharacters)
        let cleaned = raw
            .components(separatedBy: disallowed)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let capped = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? "Podcast Episode" : capped
    }
}

/// Bridges `URLSessionDownloadTask` callbacks to an async continuation. All
/// mutable state is guarded by an `OSAllocatedUnfairLock`, so `@unchecked
/// Sendable` is sound. The temp file from `didFinishDownloadingTo` is moved to a
/// stable location synchronously (it is deleted once the delegate returns).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        var lastPercent = -1
        var resumed = false
    }

    private let onProgress: (@Sendable (Int) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(onProgress: (@Sendable (Int) -> Void)?) {
        self.onProgress = onProgress
    }

    func attach(_ continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let onProgress, totalBytesExpectedToWrite > 0 else { return }
        let percent = PodcastAudioDownloader.progressPercent(
            downloaded: totalBytesWritten,
            total: totalBytesExpectedToWrite
        )
        let shouldEmit = state.withLock { st -> Bool in
            guard st.lastPercent != percent else { return false }
            st.lastPercent = percent
            return true
        }
        if shouldEmit { onProgress(percent) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let response = downloadTask.response ?? URLResponse()
        let stableURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mpk-podcast-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: stableURL)
            resume(.success((stableURL, response)))
        } catch {
            resume(.failure(PodcastAudioFetchError.writeFailed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return } // success already resumed in didFinishDownloadingTo
        if (error as NSError).code == NSURLErrorCancelled {
            resume(.failure(CancellationError()))
        } else {
            resume(.failure(PodcastAudioFetchError.requestFailed(error.localizedDescription)))
        }
    }

    private func resume(_ result: Result<(URL, URLResponse), Error>) {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>? = state.withLock { st in
            guard !st.resumed else { return nil }
            st.resumed = true
            let cont = st.continuation
            st.continuation = nil
            return cont
        }
        continuation?.resume(with: result)
    }
}

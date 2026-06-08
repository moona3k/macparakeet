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
/// Swift port of `podcast-fetch`'s `download_episode` — a plain HTTP(S)
/// streaming download (URLSession follows the tracking-prefix redirects podcast
/// CDNs use). No `yt-dlp` needed; the file lands in the shared app downloads
/// directory so the existing retention + cleanup paths apply.
public actor PodcastAudioDownloader: PodcastAudioFetching {
    private static let knownAudioExtensions: Set<String> = [
        "mp3", "m4a", "mp4", "aac", "ogg", "oga", "opus", "wav", "flac", "wma", "webm", "aiff",
    ]
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "PodcastAudioDownloader")
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
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

        let outputURL: URL
        let bytes: URLSession.AsyncBytes
        let expectedLength: Int64
        do {
            let (asyncBytes, response) = try await session.bytes(for: request)
            bytes = asyncBytes
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw PodcastAudioFetchError.requestFailed("HTTP \(http.statusCode)")
            }
            expectedLength = response.expectedContentLength
            let ext = Self.fileExtension(for: url, response: response)
            outputURL = Self.uniqueOutputURL(
                in: URL(fileURLWithPath: downloadsDir, isDirectory: true),
                suggestedName: suggestedName,
                fileExtension: ext
            )
        } catch let error as PodcastAudioFetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PodcastAudioFetchError.requestFailed(error.localizedDescription)
        }

        guard fm.createFile(atPath: outputURL.path, contents: nil) else {
            throw PodcastAudioFetchError.writeFailed("could not create file")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: outputURL)
        } catch {
            throw PodcastAudioFetchError.writeFailed(error.localizedDescription)
        }

        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded {
                try? fm.removeItem(at: outputURL)
            }
        }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var downloaded: Int64 = 0
        var lastPercent = -1

        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    downloaded += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    Self.emitProgress(downloaded: downloaded, total: expectedLength, last: &lastPercent, onProgress: onProgress)
                    try Task.checkCancellation()
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                downloaded += Int64(buffer.count)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PodcastAudioFetchError {
            throw error
        } catch {
            throw PodcastAudioFetchError.requestFailed(error.localizedDescription)
        }

        Self.emitProgress(downloaded: downloaded, total: expectedLength, last: &lastPercent, onProgress: onProgress, forceComplete: true)
        succeeded = true
        logger.info("podcast_audio_fetched bytes=\(downloaded, privacy: .public)")
        return outputURL
    }

    // MARK: - Helpers

    static func progressPercent(downloaded: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        let pct = (Double(downloaded) / Double(total)) * 100.0
        return max(0, min(Int(pct), 100))
    }

    private static func emitProgress(
        downloaded: Int64,
        total: Int64,
        last: inout Int,
        onProgress: (@Sendable (Int) -> Void)?,
        forceComplete: Bool = false
    ) {
        guard let onProgress else { return }
        let percent = forceComplete && total > 0 ? 100 : progressPercent(downloaded: downloaded, total: total)
        if percent != last {
            last = percent
            onProgress(percent)
        }
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

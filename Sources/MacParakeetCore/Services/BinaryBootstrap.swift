import CryptoKit
import Foundation
import os

public enum BinaryBootstrapError: Error, LocalizedError {
    case downloadFailed(String)
    case checksumUnavailable(String)
    case checksumMismatch(String)
    case installFailed(String)
    case updateTimedOut
    case bundledFFmpegMissing

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "Binary download failed: \(message)"
        case .checksumUnavailable(let message):
            return "Could not verify binary checksum: \(message)"
        case .checksumMismatch(let message):
            return "Binary checksum mismatch: \(message)"
        case .installFailed(let message):
            return "Binary install failed: \(message)"
        case .updateTimedOut:
            return "Binary update timed out"
        case .bundledFFmpegMissing:
            return "Bundled FFmpeg is missing from app resources"
        }
    }
}

public actor BinaryBootstrap {
    private static let ytDlpAssetArm64 = "yt-dlp_macos"
    // yt-dlp currently publishes a single macOS binary asset name.
    private static let ytDlpAssetX86 = "yt-dlp_macos"
    private static let ytDlpLatestBaseURL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download"
    private static let ytDlpChecksumsFile = "SHA2-256SUMS"
    private static let ytDlpUpdateInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let ytDlpLastUpdateCheckKey = "ytDlp.lastUpdateCheckAt"

    private let session: URLSession
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let ensureDirectories: @Sendable () throws -> Void
    private let ytDlpBinaryPath: @Sendable () -> String
    private let bundledYtDlpPath: @Sendable () -> String?
    private let tempDirPath: @Sendable () -> String

    public init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default,
        ensureDirectories: @escaping @Sendable () throws -> Void = { try AppPaths.ensureDirectories() },
        ytDlpBinaryPath: @escaping @Sendable () -> String = { AppPaths.ytDlpBinaryPath },
        bundledYtDlpPath: @escaping @Sendable () -> String? = { AppPaths.bundledYtDlpPath() },
        tempDirPath: @escaping @Sendable () -> String = { AppPaths.tempDir }
    ) {
        self.session = session
        self.defaults = defaults
        self.now = now
        self.fileManager = fileManager
        self.ensureDirectories = ensureDirectories
        self.ytDlpBinaryPath = ytDlpBinaryPath
        self.bundledYtDlpPath = bundledYtDlpPath
        self.tempDirPath = tempDirPath
    }

    public func ensureYtDlpAvailable(allowNetworkUpdate: Bool = false) async throws -> String {
        try ensureDirectories()

        let targetPath = ytDlpBinaryPath()
        if allowNetworkUpdate {
            try await installYtDlp(at: targetPath)
            defaults.set(now(), forKey: Self.ytDlpLastUpdateCheckKey)
            return targetPath
        }

        if fileManager.isExecutableFile(atPath: targetPath) {
            return targetPath
        }

        if let bundledPath = bundledYtDlpPath(),
           fileManager.isExecutableFile(atPath: bundledPath)
        {
            try installExecutable(from: URL(fileURLWithPath: bundledPath), toPath: targetPath)
            return targetPath
        }

        try await installYtDlp(at: targetPath)
        return targetPath
    }

    public nonisolated static func resolveYtDlpPath(
        fileManager: FileManager = .default,
        managedPath: String = AppPaths.ytDlpBinaryPath,
        bundledPath: String? = AppPaths.bundledYtDlpPath()
    ) -> String? {
        if fileManager.isExecutableFile(atPath: managedPath) {
            return managedPath
        }
        if let bundledPath, fileManager.isExecutableFile(atPath: bundledPath) {
            return bundledPath
        }
        return nil
    }

    /// Weekly non-blocking update. Failures are intentionally ignored.
    public func autoUpdateYtDlpIfNeeded() async {
        guard shouldRunYtDlpUpdateCheck() else { return }

        let binaryPath = ytDlpBinaryPath()
        guard fileManager.isExecutableFile(atPath: binaryPath) else { return }

        do {
            // Re-install from GitHub with checksum verification
            // (same download-verify-replace flow as fresh install)
            try await installYtDlp(at: binaryPath)
            // Only record success — failed updates retry on next launch instead of
            // waiting a full week.
            defaults.set(now(), forKey: Self.ytDlpLastUpdateCheckKey)
        } catch {
            // Non-blocking by design — update failures are silently ignored.
            // Next app launch will retry since we didn't update the timestamp.
        }
    }

    public nonisolated static func requireBundledFFmpegPath() throws -> String {
        guard let ffmpegPath = AppPaths.bundledFFmpegPath() else {
            throw BinaryBootstrapError.bundledFFmpegMissing
        }
        return ffmpegPath
    }

    /// Resolve FFmpeg for current runtime:
    /// - App bundle path in production.
    /// - Development fallback (`swift run` / tests) via env override or PATH.
    public nonisolated static func requireRuntimeFFmpegPath() throws -> String {
        guard let ffmpegPath = resolveRuntimeFFmpegPath() else {
            throw BinaryBootstrapError.bundledFFmpegMissing
        }
        return ffmpegPath
    }

    public nonisolated static func resolveRuntimeFFmpegPath(
        bundledFFmpegPath: String? = AppPaths.bundledFFmpegPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let bundledFFmpegPath,
           fileManager.isExecutableFile(atPath: bundledFFmpegPath)
        {
            return bundledFFmpegPath
        }

        if let override = environment["MACPARAKEET_FFMPEG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override)
        {
            return override
        }

        let extendedPATH = Self.extendedPATH(from: environment["PATH"])
        if let discovered = findExecutable(named: "ffmpeg", inPATH: extendedPATH, fileManager: fileManager) {
            return discovered
        }

        return nil
    }

    /// Find FFmpeg via PATH search only (skips bundled binary).
    /// Used as a fallback when the bundled FFmpeg fails at runtime (e.g., dyld Team ID mismatch).
    public nonisolated static func findSystemFFmpeg(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        let extendedPATH = Self.extendedPATH(from: environment["PATH"])
        return findExecutable(named: "ffmpeg", inPATH: extendedPATH, fileManager: fileManager)
    }

    // MARK: - Private

    private func shouldRunYtDlpUpdateCheck() -> Bool {
        guard let lastCheck = defaults.object(forKey: Self.ytDlpLastUpdateCheckKey) as? Date else {
            return true
        }
        return now().timeIntervalSince(lastCheck) >= Self.ytDlpUpdateInterval
    }

    private func installYtDlp(at targetPath: String) async throws {
        let assetName = Self.currentYtDlpAssetName()

        guard
            let binaryURL = URL(string: "\(Self.ytDlpLatestBaseURL)/\(assetName)"),
            let checksumsURL = URL(string: "\(Self.ytDlpLatestBaseURL)/\(Self.ytDlpChecksumsFile)")
        else {
            throw BinaryBootstrapError.downloadFailed("Invalid yt-dlp download URL")
        }

        let tempDir = URL(fileURLWithPath: tempDirPath(), isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let tempBinaryURL = tempDir.appendingPathComponent("yt-dlp-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: tempBinaryURL)
        }

        try await download(url: binaryURL, to: tempBinaryURL)
        let checksums = try await fetchText(from: checksumsURL)
        let expectedChecksum = try Self.extractChecksum(for: assetName, from: checksums)
        let actualChecksum = try Self.sha256Hex(ofFileAt: tempBinaryURL)

        guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
            throw BinaryBootstrapError.checksumMismatch("Expected \(expectedChecksum), got \(actualChecksum)")
        }

        try installExecutable(from: tempBinaryURL, toPath: targetPath)
    }

    private func download(url: URL, to destination: URL) async throws {
        let (tmpURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw BinaryBootstrapError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) from \(url.absoluteString)")
        }

        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: tmpURL, to: destination)
        } catch {
            throw BinaryBootstrapError.installFailed(error.localizedDescription)
        }
    }

    private func fetchText(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw BinaryBootstrapError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) from \(url.absoluteString)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BinaryBootstrapError.checksumUnavailable("Checksum file is not valid UTF-8")
        }
        return text
    }

    private func installExecutable(from sourceURL: URL, toPath targetPath: String) throws {
        let targetURL = URL(fileURLWithPath: targetPath)
        let targetDir = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Stage the new binary next to the target with permissions set BEFORE swapping.
        // This ensures the old binary stays in place if anything fails.
        let stagedURL = targetDir.appendingPathComponent(".\(targetURL.lastPathComponent).staged")
        defer { try? fileManager.removeItem(at: stagedURL) }

        do {
            if fileManager.fileExists(atPath: stagedURL.path) {
                try fileManager.removeItem(at: stagedURL)
            }
            try fileManager.copyItem(at: sourceURL, to: stagedURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedURL.path)
        } catch {
            throw BinaryBootstrapError.installFailed(error.localizedDescription)
        }

        // Atomic swap: old binary is preserved until the new one is fully in place.
        if fileManager.fileExists(atPath: targetPath) {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: targetURL)
        }
    }

    private nonisolated static func currentYtDlpAssetName() -> String {
        #if arch(arm64)
        return ytDlpAssetArm64
        #else
        return ytDlpAssetX86
        #endif
    }

    /// Extend PATH with common binary locations that macOS GUI apps don't inherit.
    private nonisolated static func extendedPATH(from basePATH: String?) -> String {
        let current = basePATH ?? "/usr/bin:/bin"
        let extras = [
            AppPaths.binDir,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let existing = Set(current.split(separator: ":").map(String.init))
        let missing = extras.filter { !existing.contains($0) }
        return ([current] + missing).joined(separator: ":")
    }

    private nonisolated static func findExecutable(
        named binaryName: String,
        inPATH path: String,
        fileManager: FileManager
    ) -> String? {
        for rawComponent in path.split(separator: ":") {
            let component = String(rawComponent)
            guard !component.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: component, isDirectory: true)
                .appendingPathComponent(binaryName)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func extractChecksum(for assetName: String, from checksums: String) throws -> String {
        for line in checksums.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            let checksum = String(parts[0])
            let fileName = String(parts[1])
            if fileName == assetName {
                return checksum
            }
        }
        throw BinaryBootstrapError.checksumUnavailable("No checksum found for \(assetName)")
    }

    private nonisolated static func sha256Hex(ofFileAt fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

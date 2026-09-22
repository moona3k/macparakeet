import Darwin
import Foundation

public enum VoiceControlBrowserChoice: String, CaseIterable, Identifiable, Sendable {
    case chrome, chromium, chromeForTesting
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .chromium: return "Chromium"
        case .chromeForTesting: return "Chrome for Testing"
        }
    }
    var supportPath: String {
        switch self {
        case .chrome: return "Google/Chrome"
        case .chromium: return "Chromium"
        case .chromeForTesting: return "Google/ChromeForTesting"
        }
    }
}

/// Explicit, user-scoped setup. Registration never starts or relaunches a browser.
public struct VoiceControlBrowserRegistration: Sendable {
    public enum RegistrationError: Error, LocalizedError {
        case invalidExtensionID, missingHost, insecurePath, conflictingPairing, conflictingManifest, bridgeRunning,
            writeFailed
        public var errorDescription: String? {
            switch self {
            case .invalidExtensionID:
                return "Enter the extension's exact 32-letter ID from your browser's extensions page."
            case .missingHost:
                return "This app does not contain its browser helper. Install a complete MacParakeet build."
            case .insecurePath:
                return
                    "Browser setup found an unexpected file owner, permission, or symbolic link. Existing files were preserved."
            case .conflictingPairing:
                return "Another extension is paired. Select Replace existing pairing if you intend to change it."
            case .conflictingManifest: return "An unrelated browser registration already exists. It was preserved."
            case .bridgeRunning: return "Disconnect browser Voice Control before changing its registration."
            case .writeFailed:
                return "Browser registration could not be saved. Existing registration was preserved where possible."
            }
        }
    }

    private let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public static func bundledHostURL(bundle: Bundle = .main) -> URL? {
        guard let executable = bundle.executableURL else { return nil }
        let host = executable.deletingLastPathComponent().appendingPathComponent("macparakeet-browser-host")
        return FileManager.default.isExecutableFile(atPath: host.path) ? host : nil
    }

    public static func bundledExtensionURL(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let folder = resources.appendingPathComponent("VoiceControlBrowser", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path)
            ? folder : nil
    }

    public func register(
        extensionID: String, browser: VoiceControlBrowserChoice, hostURL: URL,
        replaceExisting: Bool = false
    ) async throws {
        try await Task.detached {
            try self.performRegistration(
                extensionID: extensionID, browser: browser, hostURL: hostURL,
                replaceExisting: replaceExisting)
        }.value
    }

    private struct Manifest: Codable {
        let name: String
        let description: String
        let path: String
        let type: String
        let allowed_origins: [String]
    }

    private func performRegistration(
        extensionID: String, browser: VoiceControlBrowserChoice, hostURL: URL,
        replaceExisting: Bool
    ) throws {
        let extensionID = extensionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard extensionID.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil else {
            throw RegistrationError.invalidExtensionID
        }
        guard hostURL.isFileURL, FileManager.default.isExecutableFile(atPath: hostURL.path) else {
            throw RegistrationError.missingHost
        }
        let support = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = support.appendingPathComponent("MacParakeet/VoiceControlBrowser", isDirectory: true)
        try ensureDirectory(directory, privateMode: true)
        let lockURL = directory.appendingPathComponent("bridge.lock")
        let lock = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw RegistrationError.insecurePath }
        defer { Darwin.close(lock) }
        var metadata = stat()
        guard fstat(lock, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_mode & 0o777 == 0o600
        else {
            throw RegistrationError.insecurePath
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw RegistrationError.bridgeRunning }

        let configURL = directory.appendingPathComponent("pairing.json")
        let existingConfigData = try readOwnedRegularFile(configURL, privateMode: true)
        let existing: VoiceControlBrowserWire.Configuration?
        do {
            existing = try existingConfigData.map {
                try JSONDecoder().decode(VoiceControlBrowserWire.Configuration.self, from: $0)
            }
        } catch { throw RegistrationError.conflictingPairing }
        let origin = "chrome-extension://\(extensionID)/"
        if let existing, existing.extensionOrigin != origin, !replaceExisting {
            throw RegistrationError.conflictingPairing
        }
        if let existing, existing.token.count < 64 { throw RegistrationError.conflictingPairing }

        let manifestDirectory = support.appendingPathComponent(browser.supportPath, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try ensureDirectory(manifestDirectory, privateMode: false)
        let manifestURL = manifestDirectory.appendingPathComponent("com.macparakeet.voice_control.json")
        let oldManifest = try readOwnedRegularFile(manifestURL, privateMode: false)
        if let oldManifest {
            guard let decoded = try? JSONDecoder().decode(Manifest.self, from: oldManifest),
                decoded.name == "com.macparakeet.voice_control", decoded.type == "stdio",
                decoded.allowed_origins == [existing?.extensionOrigin ?? origin]
            else {
                throw RegistrationError.conflictingManifest
            }
        }
        let token =
            existing?.extensionOrigin == origin
            ? existing!.token
            : UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configuration = VoiceControlBrowserWire.Configuration(extensionOrigin: origin, token: token)
        let configData = try encoder.encode(configuration)
        let manifestData = try encoder.encode(
            Manifest(
                name: "com.macparakeet.voice_control",
                description: "MacParakeet Voice Control", path: hostURL.standardizedFileURL.path,
                type: "stdio", allowed_origins: [origin]))
        // Stage both files before publishing either. The advisory lock also excludes the active bridge.
        let stagedConfig = try stage(configData, beside: configURL)
        defer { try? FileManager.default.removeItem(at: stagedConfig) }
        let stagedManifest = try stage(manifestData, beside: manifestURL)
        defer { try? FileManager.default.removeItem(at: stagedManifest) }
        guard Darwin.rename(stagedManifest.path, manifestURL.path) == 0 else { throw RegistrationError.writeFailed }
        guard Darwin.rename(stagedConfig.path, configURL.path) == 0 else {
            // Roll back only the manifest this invocation just installed.
            if (try? Data(contentsOf: manifestURL)) == manifestData {
                if let oldManifest, let rollback = try? stage(oldManifest, beside: manifestURL) {
                    _ = Darwin.rename(rollback.path, manifestURL.path)
                    try? FileManager.default.removeItem(at: rollback)
                } else if oldManifest == nil {
                    try? FileManager.default.removeItem(at: manifestURL)
                }
            }
            throw RegistrationError.writeFailed
        }
    }

    private func ensureDirectory(_ url: URL, privateMode: Bool) throws {
        // Reject pre-existing symlink components rather than following them into unrelated storage.
        var parent = url
        while parent.path != homeDirectory.path && parent.path != "/" {
            var metadata = stat()
            if lstat(parent.path, &metadata) == 0,
                metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR)
            {
                throw RegistrationError.insecurePath
            }
            parent.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            !privateMode || metadata.st_mode & 0o777 == 0o700
        else { throw RegistrationError.insecurePath }
    }

    private func readOwnedRegularFile(_ url: URL, privateMode: Bool) throws -> Data? {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return nil }; throw RegistrationError.insecurePath
        }
        guard metadata.st_uid == getuid(), metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            !privateMode || metadata.st_mode & 0o777 == 0o600, metadata.st_size <= 16_384
        else {
            throw RegistrationError.insecurePath
        }
        return try Data(contentsOf: url)
    }

    private func stage(_ data: Data, beside destination: URL) throws -> URL {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".registration-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RegistrationError.writeFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            return temporary
        } catch {
            try? handle.close(); try? FileManager.default.removeItem(at: temporary)
            throw RegistrationError.writeFailed
        }
    }
}

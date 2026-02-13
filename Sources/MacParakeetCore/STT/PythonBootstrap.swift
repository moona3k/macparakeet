import Foundation

/// Manages Python environment setup via uv for the STT daemon.
public final class PythonBootstrap: Sendable {
    private let appSupportDir: String
    // Directory that contains the Python package directory `macparakeet_stt/`.
    private let pythonRootPath: String
    // Directory of the `macparakeet_stt/` Python package (contains requirements.txt).
    private let pythonPackagePath: String

    private static let autoUpdateYouTubeEngineKey = "autoUpdateYouTubeEngine"
    private static let lastYouTubeEngineUpdateCheckKey = "youtubeEngineLastAutoUpdateCheck"
    private static let youTubeEngineUpdateInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let youTubeEnginePackages = [
        "yt-dlp>=2025.1.0,<2027.0",
        "yt-dlp-ejs>=0.3.2,<0.4.0",
    ]

    public init(
        appSupportDir: String? = nil,
        pythonRootPath: String? = nil,
        pythonPackagePath: String? = nil
    ) {
        let defaultAppSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        self.appSupportDir = appSupportDir
            ?? (defaultAppSupport + "/MacParakeet")

        // Prefer bundled resources (production app), then fall back to a local dev checkout.
        // Note: `PYTHONPATH` must point at the root directory, not at the package directory,
        // so that `python -m macparakeet_stt` can be resolved.
        let bundledPythonRoot = Bundle.main.resourcePath
            .map { $0 + "/python" }
            .flatMap { Self.isValidPythonRoot($0) ? $0 : nil }

        let discoveredFromCwd = Self.discoverDevPythonRoot(startingAt: FileManager.default.currentDirectoryPath)
        let discoveredFromExe: String? = {
            let fromBundle = Bundle.main.executableURL.flatMap { exeURL in
                Self.discoverDevPythonRoot(startingAt: exeURL.deletingLastPathComponent().path)
            }
            let fromArgs: String? = {
                guard let exePath = CommandLine.arguments.first, !exePath.isEmpty else { return nil }
                return Self.discoverDevPythonRoot(startingAt: URL(fileURLWithPath: exePath).deletingLastPathComponent().path)
            }()
            return fromBundle ?? fromArgs
        }()
        let discoveredDevRoot = discoveredFromCwd ?? discoveredFromExe

        self.pythonRootPath = pythonRootPath
            ?? bundledPythonRoot
            ?? discoveredDevRoot
            ?? "python"

        self.pythonPackagePath = pythonPackagePath
            ?? (self.pythonRootPath + "/macparakeet_stt")
    }

    /// The path to the Python venv directory
    public var venvPath: String {
        "\(appSupportDir)/python"
    }

    /// The path to the Python executable in the venv
    public var pythonExecutable: String {
        "\(venvPath)/bin/python"
    }

    /// Ensure the Python environment exists and has dependencies installed.
    /// Returns the path to the Python executable.
    public func ensureEnvironment() async throws -> String {
        try await ensureEnvironment(onProgress: nil)
    }

    /// Ensure the Python environment exists and has dependencies installed.
    /// Emits human-readable progress messages via the callback.
    /// Returns the path to the Python executable.
    public func ensureEnvironment(onProgress: (@Sendable (String) -> Void)?) async throws -> String {
        let fm = FileManager.default

        // Create app support dir if needed
        if !fm.fileExists(atPath: appSupportDir) {
            try fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        }

        let requirementsPath = "\(pythonPackagePath)/requirements.txt"

        // Check if venv already exists
        if fm.fileExists(atPath: pythonExecutable) {
            // Sync dependencies if requirements.txt has changed since last install.
            // This ensures existing users pick up new dependencies (e.g. imageio-ffmpeg)
            // without needing to delete their venv.
            if requirementsChanged(requirementsPath: requirementsPath) {
                let uvPath = try findUV()
                onProgress?("Updating dependencies...")
                try await runProcess(
                    uvPath,
                    arguments: ["pip", "install", "--python", pythonExecutable, "-r", requirementsPath]
                )
                writeRequirementsHash(requirementsPath: requirementsPath)
            }
            return pythonExecutable
        }

        // Find uv binary
        let uvPath = try findUV()

        // Create venv
        onProgress?("Creating Python environment...")
        try await runProcess(uvPath, arguments: ["venv", venvPath, "--python", "3.11"])

        // Install requirements
        if fm.fileExists(atPath: requirementsPath) {
            onProgress?("Installing dependencies (~500 MB)...")
            try await runProcess(
                uvPath,
                arguments: ["pip", "install", "--python", pythonExecutable, "-r", requirementsPath]
            )
            writeRequirementsHash(requirementsPath: requirementsPath)
        }

        return pythonExecutable
    }

    /// Best-effort periodic update for YouTube tooling. Runs at most once per week by default.
    /// Failures are intentionally swallowed so downloads continue using existing known-good versions.
    public func autoUpdateYouTubeEngineIfNeeded(defaults: UserDefaults = .standard) async {
        let enabled = defaults.object(forKey: Self.autoUpdateYouTubeEngineKey) as? Bool ?? true
        guard enabled else { return }

        let now = Date()
        if let lastCheck = defaults.object(forKey: Self.lastYouTubeEngineUpdateCheckKey) as? Date,
           now.timeIntervalSince(lastCheck) < Self.youTubeEngineUpdateInterval {
            return
        }

        // Throttle repeated checks even if update fails (e.g., offline machine).
        defaults.set(now, forKey: Self.lastYouTubeEngineUpdateCheckKey)

        do {
            _ = try await ensureEnvironment()
            let uvPath = try findUV()
            try await runProcess(
                uvPath,
                arguments: [
                    "pip", "install",
                    "--python", pythonExecutable,
                    "--upgrade",
                ] + Self.youTubeEnginePackages
            )
        } catch {
            // Best effort only; keep existing environment if update fails.
        }
    }

    /// Re-install requirements from requirements.txt into an existing venv.
    /// Use when new dependencies have been added after the venv was first created.
    public func installRequirements() async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pythonExecutable) else {
            _ = try await ensureEnvironment()
            return
        }

        let uvPath = try findUV()
        let requirementsPath = "\(pythonPackagePath)/requirements.txt"
        if fm.fileExists(atPath: requirementsPath) {
            try await runProcess(
                uvPath,
                arguments: ["pip", "install", "--python", pythonExecutable, "-r", requirementsPath]
            )
        }
    }

    /// Environment variables for the daemon process
    public func daemonEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = pythonRootPath
        env["VIRTUAL_ENV"] = venvPath

        // Ensure PATH includes the venv bin (for FFmpeg installed via imageio-ffmpeg),
        // the app Resources dir (for bundled binaries), and common Homebrew paths.
        // macOS app bundles get a minimal PATH that excludes all of these.
        var extraPaths = ["\(venvPath)/bin"]
        if let resourcePath = Bundle.main.resourcePath {
            extraPaths.append(resourcePath)
        }
        extraPaths += ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        return env
    }

    // MARK: - Private

    private var requirementsHashPath: String {
        "\(venvPath)/.requirements-hash"
    }

    private func requirementsChanged(requirementsPath: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: requirementsPath) else {
            return false
        }
        let currentHash = Self.simpleHash(data)
        guard let storedHash = try? String(contentsOfFile: requirementsHashPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true // No hash stored yet — treat as changed
        }
        return storedHash != currentHash
    }

    private func writeRequirementsHash(requirementsPath: String) {
        guard let data = FileManager.default.contents(atPath: requirementsPath) else { return }
        let hash = Self.simpleHash(data)
        try? hash.write(toFile: requirementsHashPath, atomically: true, encoding: .utf8)
    }

    /// Simple content hash (base-16 of XOR-folded bytes). Not cryptographic, just change detection.
    private static func simpleHash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV offset basis
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3 // FNV prime
        }
        return String(hash, radix: 16)
    }

    private static func discoverDevPythonRoot(startingAt startDir: String) -> String? {
        let fm = FileManager.default
        let startURL = URL(fileURLWithPath: startDir, isDirectory: true)

        // Walk up a few levels so this works whether invoked from:
        // - repo root (`python/...`)
        // - SPM build output (`.build/.../debug`)
        var current = startURL
        for _ in 0..<8 {
            let candidateRoots = [
                current.appendingPathComponent("python", isDirectory: true),
            ]

            for root in candidateRoots {
                let marker = root
                    .appendingPathComponent("macparakeet_stt", isDirectory: true)
                    .appendingPathComponent("requirements.txt", isDirectory: false)
                if fm.fileExists(atPath: marker.path) {
                    return root.path
                }
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        return nil
    }

    private static func isValidPythonRoot(_ rootPath: String) -> Bool {
        let marker = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("macparakeet_stt", isDirectory: true)
            .appendingPathComponent("requirements.txt", isDirectory: false)
            .path
        return FileManager.default.fileExists(atPath: marker)
    }

    private func findUV() throws -> String {
        // Check bundled uv first
        if let resourcePath = Bundle.main.resourcePath {
            let fm = FileManager.default
            let direct = resourcePath.appending("/uv")
            if fm.fileExists(atPath: direct) { return direct }

            // Universal app bundles may ship arch-specific uv binaries.
            #if arch(arm64)
            let archSpecific = resourcePath.appending("/uv-arm64")
            #else
            let archSpecific = resourcePath.appending("/uv-x86_64")
            #endif
            if fm.fileExists(atPath: archSpecific) { return archSpecific }
        }

        // Check common install paths
        let searchPaths = [
            "/usr/local/bin/uv",
            "/opt/homebrew/bin/uv",
            "\(NSHomeDirectory())/.cargo/bin/uv",
            "\(NSHomeDirectory())/.local/bin/uv",
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try which
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["uv"]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice

        try whichProcess.run()
        whichProcess.waitUntilExit()

        if whichProcess.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }

        throw STTError.daemonStartFailed("uv not found. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh")
    }

    private func runProcess(_ executable: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = (process.standardError as? Pipe)
                .flatMap { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) }
                ?? "Unknown error"
            throw STTError.daemonStartFailed("Process failed (\(executable)): \(stderr)")
        }
    }
}

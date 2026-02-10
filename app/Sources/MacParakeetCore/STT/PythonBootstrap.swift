import Foundation

/// Manages Python environment setup via uv for the STT daemon.
public final class PythonBootstrap: Sendable {
    private let appSupportDir: String
    // Directory that contains the Python package directory `macparakeet_stt/`.
    private let pythonRootPath: String
    // Directory of the `macparakeet_stt/` Python package (contains requirements.txt).
    private let pythonPackagePath: String

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
        let fm = FileManager.default

        // Create app support dir if needed
        if !fm.fileExists(atPath: appSupportDir) {
            try fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        }

        // Check if venv already exists
        if fm.fileExists(atPath: pythonExecutable) {
            return pythonExecutable
        }

        // Find uv binary
        let uvPath = try findUV()

        // Create venv
        try await runProcess(uvPath, arguments: ["venv", venvPath, "--python", "3.11"])

        // Install requirements
        let requirementsPath = "\(pythonPackagePath)/requirements.txt"
        if fm.fileExists(atPath: requirementsPath) {
            try await runProcess(
                uvPath,
                arguments: ["pip", "install", "--python", pythonExecutable, "-r", requirementsPath]
            )
        }

        return pythonExecutable
    }

    /// Environment variables for the daemon process
    public func daemonEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = pythonRootPath
        env["VIRTUAL_ENV"] = venvPath
        return env
    }

    // MARK: - Private

    private static func discoverDevPythonRoot(startingAt startDir: String) -> String? {
        let fm = FileManager.default
        let startURL = URL(fileURLWithPath: startDir, isDirectory: true)

        // Walk up a few levels so this works whether invoked from:
        // - repo root (`app/python/...`)
        // - app dir (`python/...`)
        // - SPM build output (`.build/.../debug`)
        var current = startURL
        for _ in 0..<8 {
            let candidateRoots = [
                current.appendingPathComponent("python", isDirectory: true),
                current.appendingPathComponent("app/python", isDirectory: true),
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

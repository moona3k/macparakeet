import Foundation

/// Manages the cleanup CLI's heavyweight Python dependencies (mlx, mlx-lm,
/// transformers, ...). We deliberately do not bundle these — they're hundreds
/// of MB and would dominate the app DMG. Instead, the user clicks "Install
/// Python dependencies" in Settings and we shell out to
/// `/usr/bin/python3 -m pip install --target=<app support>/cleanup-runtime/site-packages`.
///
/// A `.ready-vN` sentinel file marks a successful install; bumping
/// `requirementsVersion` invalidates older installs so a future requirements
/// bump prompts the user to reinstall.
public final class CleanupRuntimeBootstrap: @unchecked Sendable {
    /// Bump when `cleanup/requirements.txt` changes meaningfully so existing
    /// installs are invalidated and re-installed on next use.
    public static let requirementsVersion = 1

    public enum Status: Sendable, Equatable {
        case missing
        case ready
        /// Sentinel from an older requirements version. Treat as missing
        /// for blocking purposes but surface a different message in UI.
        case outdated(installedVersion: Int)
    }

    public enum BootstrapError: Error, LocalizedError, Sendable {
        case requirementsFileMissing
        case pythonNotFound
        case pipFailed(exitCode: Int32, log: String)
        case spawnFailed(String)

        public var errorDescription: String? {
            switch self {
            case .requirementsFileMissing:
                return "Cannot find cleanup/requirements.txt in the app bundle. This build is broken; reinstall MacParakeet."
            case .pythonNotFound:
                return "/usr/bin/python3 was not found. Install Xcode Command Line Tools (`xcode-select --install`) and try again."
            case .pipFailed(let code, let log):
                let snippet = log.suffix(800)
                return "pip install failed (exit \(code)).\n\n\(snippet)"
            case .spawnFailed(let detail):
                return "Failed to launch python: \(detail)"
            }
        }
    }

    public struct ProgressEvent: Sendable {
        public let line: String
        /// Best-effort fraction in [0, 1]; nil means "indeterminate". pip
        /// doesn't emit clean progress, so we leave this nil and let the UI
        /// render a streaming log.
        public let fraction: Double?
    }

    private let fileManager: FileManager
    private let runtimeDir: String
    private let sitePackagesDir: String
    private let bundledRequirementsPath: String?

    public init(
        fileManager: FileManager = .default,
        runtimeDir: String = AppPaths.cleanupRuntimeDir,
        sitePackagesDir: String = AppPaths.cleanupRuntimeSitePackagesDir,
        bundledRequirementsPath: String? = AppPaths.bundledCleanupRequirementsPath()
    ) {
        self.fileManager = fileManager
        self.runtimeDir = runtimeDir
        self.sitePackagesDir = sitePackagesDir
        self.bundledRequirementsPath = bundledRequirementsPath
    }

    /// Cheap probe — call from view models to drive button state.
    public func currentStatus() -> Status {
        let currentMarker = AppPaths.cleanupRuntimeReadyMarker(version: Self.requirementsVersion)
        if fileManager.fileExists(atPath: currentMarker) {
            return .ready
        }
        if let installed = installedVersion() {
            return .outdated(installedVersion: installed)
        }
        return .missing
    }

    /// Install or re-install the managed runtime. Streams pip output via
    /// `progress`; the closure is called on an arbitrary queue. Throws
    /// `BootstrapError` on failure.
    ///
    /// Idempotent: running while already-ready is allowed and just re-runs
    /// pip (pip itself short-circuits when packages are up-to-date).
    public func install(
        progress: @Sendable @escaping (ProgressEvent) -> Void
    ) async throws {
        guard let requirementsPath = bundledRequirementsPath else {
            throw BootstrapError.requirementsFileMissing
        }
        guard fileManager.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw BootstrapError.pythonNotFound
        }
        try fileManager.createDirectory(
            atPath: sitePackagesDir,
            withIntermediateDirectories: true
        )

        let priorMarker = priorReadyMarkerPath()
        if let priorMarker {
            try? fileManager.removeItem(atPath: priorMarker)
        }

        try await runPipInstall(
            requirementsPath: requirementsPath,
            progress: progress
        )

        let marker = AppPaths.cleanupRuntimeReadyMarker(version: Self.requirementsVersion)
        try Data().write(to: URL(fileURLWithPath: marker))
    }

    /// Remove the entire managed runtime. Free for the user to reclaim disk
    /// space — they can reinstall via the same Settings button.
    public func uninstall() throws {
        if fileManager.fileExists(atPath: runtimeDir) {
            try fileManager.removeItem(atPath: runtimeDir)
        }
    }

    // MARK: - Private

    private func installedVersion() -> Int? {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: runtimeDir) else {
            return nil
        }
        var maxVersion: Int?
        for name in entries {
            guard name.hasPrefix(".ready-v"), let v = Int(name.dropFirst(".ready-v".count)) else {
                continue
            }
            if maxVersion == nil || v > maxVersion! { maxVersion = v }
        }
        return maxVersion
    }

    private func priorReadyMarkerPath() -> String? {
        guard let installed = installedVersion(), installed != Self.requirementsVersion else {
            return nil
        }
        return AppPaths.cleanupRuntimeReadyMarker(version: installed)
    }

    private func runPipInstall(
        requirementsPath: String,
        progress: @Sendable @escaping (ProgressEvent) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try self.runPipInstallSync(
                        requirementsPath: requirementsPath,
                        progress: progress
                    )
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func runPipInstallSync(
        requirementsPath: String,
        progress: @Sendable @escaping (ProgressEvent) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-m", "pip", "install",
            "--no-input",
            "--disable-pip-version-check",
            "--target", sitePackagesDir,
            "--upgrade",
            "-r", requirementsPath,
        ]

        var env = ProcessInfo.processInfo.environment
        // Force pip to use a clean user-isolated working dir so we don't
        // inherit the user's shell pip config.
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let logBox = LogBox()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let s = String(line)
                logBox.append(s)
                progress(ProgressEvent(line: s, fraction: nil))
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let s = String(line)
                logBox.append(s)
                progress(ProgressEvent(line: s, fraction: nil))
            }
        }

        do {
            try process.run()
        } catch {
            throw BootstrapError.spawnFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            throw BootstrapError.pipFailed(exitCode: exitCode, log: logBox.joined())
        }
    }

    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }
}

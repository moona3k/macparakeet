import Foundation

/// Downloads MLX model snapshots into the cleanup CLI's `HF_HOME` cache so
/// the daemon can `mlx_lm.load(model_id)` without hitting the network.
///
/// Implemented by shelling out to `huggingface_hub.snapshot_download` running
/// against the managed Python runtime (so we reuse the user's existing
/// install instead of pulling another HTTP client into Swift). That keeps
/// version-skew between download path and load path zero.
public final class LocalFormattingModelDownloader: @unchecked Sendable {
    public enum DownloadError: Error, LocalizedError, Sendable {
        case runtimeNotInstalled
        case spawnFailed(String)
        case nonZeroExit(code: Int32, log: String)

        public var errorDescription: String? {
            switch self {
            case .runtimeNotInstalled:
                return "Python dependencies aren't installed yet. Click \"Install Python dependencies\" first."
            case .spawnFailed(let detail):
                return "Failed to launch python: \(detail)"
            case .nonZeroExit(let code, let log):
                let snippet = log.suffix(800)
                return "Model download failed (exit \(code)).\n\n\(snippet)"
            }
        }
    }

    public struct ProgressEvent: Sendable {
        public let line: String
    }

    private let fileManager: FileManager
    private let bootstrap: CleanupRuntimeBootstrap
    private let hfHome: String
    private let sitePackagesDir: String

    public init(
        fileManager: FileManager = .default,
        bootstrap: CleanupRuntimeBootstrap = CleanupRuntimeBootstrap(),
        hfHome: String = AppPaths.llmModelsHFHome,
        sitePackagesDir: String = AppPaths.cleanupRuntimeSitePackagesDir
    ) {
        self.fileManager = fileManager
        self.bootstrap = bootstrap
        self.hfHome = hfHome
        self.sitePackagesDir = sitePackagesDir
    }

    /// Cheap probe — true when at least one snapshot exists for the model.
    public func isDownloaded(modelID: String) -> Bool {
        let dir = modelHubDir(modelID: modelID)
        let snapshots = (dir as NSString).appendingPathComponent("snapshots")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: snapshots) else {
            return false
        }
        // Any non-empty snapshot dir is good enough; mlx_lm.load picks the
        // resolved revision via its own logic.
        for name in entries {
            let snapDir = (snapshots as NSString).appendingPathComponent(name)
            if let contents = try? fileManager.contentsOfDirectory(atPath: snapDir),
               !contents.isEmpty {
                return true
            }
        }
        return false
    }

    public func download(
        modelID: String,
        progress: @Sendable @escaping (ProgressEvent) -> Void
    ) async throws {
        guard bootstrap.currentStatus() == .ready else {
            throw DownloadError.runtimeNotInstalled
        }
        try fileManager.createDirectory(
            atPath: hfHome, withIntermediateDirectories: true
        )

        try await runSnapshotDownload(modelID: modelID, progress: progress)
    }

    public func delete(modelID: String) throws {
        let dir = modelHubDir(modelID: modelID)
        if fileManager.fileExists(atPath: dir) {
            try fileManager.removeItem(atPath: dir)
        }
    }

    // MARK: - Private

    private func modelHubDir(modelID: String) -> String {
        // Hugging Face turns `org/name` into `models--org--name` under
        // `$HF_HOME/hub/`. We mirror that convention rather than calling
        // huggingface_hub for a path lookup.
        let safe = modelID.replacingOccurrences(of: "/", with: "--")
        return "\(hfHome)/hub/models--\(safe)"
    }

    private func runSnapshotDownload(
        modelID: String,
        progress: @Sendable @escaping (ProgressEvent) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try self.runSnapshotDownloadSync(modelID: modelID, progress: progress)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func runSnapshotDownloadSync(
        modelID: String,
        progress: @Sendable @escaping (ProgressEvent) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Unbuffered + tqdm in plain mode → readable progress lines.
        let script = """
        import os, sys
        from huggingface_hub import snapshot_download
        repo_id = sys.argv[1]
        path = snapshot_download(repo_id=repo_id)
        print(f"OK {path}")
        """
        process.arguments = ["-u", "-c", script, modelID]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = sitePackagesDir
        env["HF_HOME"] = hfHome
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "0"
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
                progress(ProgressEvent(line: s))
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let s = String(line)
                logBox.append(s)
                progress(ProgressEvent(line: s))
            }
        }

        do {
            try process.run()
        } catch {
            throw DownloadError.spawnFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            throw DownloadError.nonZeroExit(code: exitCode, log: logBox.joined())
        }
    }

    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }
}

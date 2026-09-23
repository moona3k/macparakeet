import Foundation

/// Optional local Photon adapter for moondream/parakeet-redux. Photon currently
/// ships as a Python wheel, so its environment and Hugging Face cache live in a
/// separate, user-deletable directory rather than inside FluidAudio's cache.
public enum PhotonReduxEngine {
    public static let modelID = "moondream/parakeet-redux"

    private static var directory: URL {
        URL(fileURLWithPath: AppPaths.appSupportDir, isDirectory: true)
            .appendingPathComponent("models/stt/parakeet-redux", isDirectory: true)
    }

    private static var python: URL {
        directory.appendingPathComponent("venv/bin/python3")
    }

    private static var marker: URL {
        directory.appendingPathComponent(".ready")
    }

    private static var modelSnapshots: URL {
        directory.appendingPathComponent(
            "huggingface/hub/models--moondream--parakeet-redux/snapshots",
            isDirectory: true
        )
    }

    public static var isModelCached: Bool {
        guard FileManager.default.fileExists(atPath: marker.path),
              FileManager.default.isExecutableFile(atPath: python.path),
              let snapshots = try? FileManager.default.contentsOfDirectory(atPath: modelSnapshots.path)
        else { return false }
        return !snapshots.isEmpty
    }

    @discardableResult
    public static func deleteModel() -> Bool {
        STTRuntime.removeParakeetModelFiles(at: directory)
    }

    public static func downloadModel(
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try await PhotonReduxInstaller.shared.install(onProgress: onProgress)
    }

    public static func transcribe(
        audioPath: String,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await downloadModel()
        try Task.checkCancellation()
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-redux-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: resultURL) }
        onProgress?(0, 100)
        try await run(
            python,
            arguments: ["-c", photonScript, "transcribe", audioPath, resultURL.path],
            offline: true
        )
        let data = try Data(contentsOf: resultURL)
        let result = try decodeResponse(data)
        onProgress?(100, 100)
        return result
    }

    static func decodeResponse(_ data: Data) throws -> STTResult {
        let response = try JSONDecoder().decode(PhotonResponse.self, from: data)
        return STTResult(
            text: response.text,
            words: response.segments.flatMap { segment in
                segment.words.map { word in
                    TimestampedWord(
                        word: word.word,
                        startMs: Int((word.start * 1000).rounded()),
                        endMs: Int((word.end * 1000).rounded()),
                        // Photon does not return confidence; this legacy
                        // non-optional field uses zero as its unavailable value.
                        confidence: 0
                    )
                }
            },
            engine: .parakeet,
            engineVariant: ParakeetModelVariant.redux.rawValue
        )
    }

    private struct PhotonResponse: Decodable {
        struct Segment: Decodable {
            struct Word: Decodable {
                let word: String
                let start: Double
                let end: Double
            }
            let words: [Word]
        }
        let text: String
        let segments: [Segment]
    }

    // The Python side writes one bounded JSON result to a file. No audio or
    // transcript is sent to a service; HF_HOME is confined to this model's cache.
    private static let photonScript = """
        import json
        import sys
        import moondream as md

        with md.photon("moondream/parakeet-redux", device="cpu") as speech:
            if sys.argv[1] == "transcribe":
                result = speech.transcribe(audio=sys.argv[2], timestamps="word")
                with open(sys.argv[3], "w", encoding="utf-8") as output:
                    json.dump(result, output)
        """

    fileprivate static func install(onProgress: (@Sendable (String) -> Void)?) async throws {
        if isModelCached { return }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try? files.removeItem(at: marker)
        if !files.isExecutableFile(atPath: python.path) {
            onProgress?("Creating local Python environment for Parakeet Redux...")
            let systemPython = try await findPython()
            try await run(systemPython, arguments: ["-m", "venv", directory.appendingPathComponent("venv").path])
        }
        onProgress?("Installing Moondream Photon runtime...")
        try await run(python, arguments: ["-m", "pip", "install", "--only-binary=:all:", "moondream==2.4.1"])
        onProgress?("Downloading Parakeet Redux weights...")
        try await run(python, arguments: ["-c", photonScript, "prepare"])
        try Task.checkCancellation()
        try (modelID + "\n").write(to: marker, atomically: true, encoding: .utf8)
    }

    private static func findPython() async throws -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin"] + paths + ["/usr/bin"]
        for name in ["python3.13", "python3.12", "python3.11", "python3.10", "python3.14", "python3"] {
            for path in candidates {
                let candidate = URL(fileURLWithPath: path).appendingPathComponent(name)
                guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
                guard (try? await run(candidate, arguments: ["-c", "import sys; assert (3, 10) <= sys.version_info[:2] <= (3, 14)"])) != nil else { continue }
                let probe = FileManager.default.temporaryDirectory
                    .appendingPathComponent("parakeet-redux-venv-probe-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: probe) }
                if (try? await run(candidate, arguments: ["-m", "venv", probe.path])) != nil {
                    return candidate
                }
            }
        }
        throw STTError.engineStartFailed("Parakeet Redux needs Python 3.10–3.14 with venv support. Install Python, then select Redux again.")
    }

    private static func run(
        _ executable: URL,
        arguments: [String],
        offline: Bool = false
    ) async throws {
        let runner = PhotonProcessRunner()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try runner.run(
                    executable: executable,
                    arguments: arguments,
                    cacheDirectory: directory.appendingPathComponent("huggingface").path,
                    offline: offline
                )
            }.value
        } onCancel: {
            runner.cancel()
        }
    }
}

private actor PhotonReduxInstaller {
    static let shared = PhotonReduxInstaller()
    private var installationTask: Task<Void, Error>?

    func install(onProgress: (@Sendable (String) -> Void)?) async throws {
        if PhotonReduxEngine.isModelCached { return }
        if let installationTask {
            try await withTaskCancellationHandler {
                try await installationTask.value
            } onCancel: {
                installationTask.cancel()
            }
            return
        }
        let task = Task { try await PhotonReduxEngine.install(onProgress: onProgress) }
        installationTask = task
        defer { installationTask = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private final class PhotonProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    func run(executable: URL, arguments: [String], cacheDirectory: String, offline: Bool) throws {
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-redux-error-\(UUID().uuidString).log")
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errorOutput = try FileHandle(forWritingTo: errorURL)
        defer { try? errorOutput.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardOutput = FileHandle.nullDevice
        child.standardError = errorOutput
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = cacheDirectory
        environment["XDG_CACHE_HOME"] = URL(fileURLWithPath: cacheDirectory)
            .deletingLastPathComponent().appendingPathComponent("cache").path
        environment["PIP_NO_CACHE_DIR"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        if offline {
            environment["HF_HUB_OFFLINE"] = "1"
        } else {
            environment.removeValue(forKey: "HF_HUB_OFFLINE")
        }
        child.environment = environment
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        process = child
        do {
            try child.run()
        } catch {
            process = nil
            lock.unlock()
            throw error
        }
        lock.unlock()
        child.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw STTError.engineStartFailed(
                detail.isEmpty ? "Photon exited with status \(child.terminationStatus)" : String(detail.suffix(1200))
            )
        }
    }
}

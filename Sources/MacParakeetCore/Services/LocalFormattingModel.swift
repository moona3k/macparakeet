import Foundation
import Darwin

// MARK: - Configuration

public enum LocalFormattingModelMode: String, Codable, Sendable, CaseIterable {
    case auto
    case rules
    case llm

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .rules: return "Rules"
        case .llm: return "LLM"
        }
    }
}

public struct LocalFormattingModelConfig: Codable, Sendable, Equatable {
    public let cliPath: String
    public let modelID: String
    public let mode: LocalFormattingModelMode
    public let timeoutSeconds: Double

    public static let defaultModelID = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    public static let minimumTimeout: Double = 5
    public static let defaultTimeout: Double = 120
    /// Sentinel meaning "use the bundled cleanup CLI from the app's Resources
    /// directory, or fall back to PATH". User overrides set this to an absolute
    /// path.
    public static let defaultCLIPath = ""

    /// Resolve the CLI path that should actually be invoked. Precedence:
    /// 1. Explicit user override in `cliPath` (non-empty, not the legacy sentinel).
    /// 2. `MACPARAKEET_CLEANUP_CLI_PATH` env override (dev workflow).
    /// 3. Bundled `Contents/Resources/cleanup/bin/macparakeet-cleanup`.
    /// 4. `macparakeet-cleanup` on PATH (last-resort).
    public func resolvedCLIPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledPath: String? = AppPaths.bundledCleanupCLIPath(),
        fileManager: FileManager = .default
    ) -> String {
        let trimmed = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "macparakeet-cleanup" {
            return trimmed
        }
        if let override = environment["MACPARAKEET_CLEANUP_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }
        if let bundledPath, fileManager.isExecutableFile(atPath: bundledPath) {
            return bundledPath
        }
        return "macparakeet-cleanup"
    }

    public init(
        cliPath: String = Self.defaultCLIPath,
        modelID: String = Self.defaultModelID,
        mode: LocalFormattingModelMode = .auto,
        timeoutSeconds: Double = Self.defaultTimeout
    ) {
        self.cliPath = cliPath
        self.modelID = modelID
        self.mode = mode
        self.timeoutSeconds = max(Self.minimumTimeout, timeoutSeconds)
    }
}

// MARK: - Config Store

// @unchecked Sendable: UserDefaults is internally thread-safe
public final class LocalFormattingModelConfigStore: @unchecked Sendable {
    private static let configKey = "local_formatting_model_config"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> LocalFormattingModelConfig? {
        guard let data = defaults.data(forKey: Self.configKey) else { return nil }
        return try? JSONDecoder().decode(LocalFormattingModelConfig.self, from: data)
    }

    public func save(_ config: LocalFormattingModelConfig) throws {
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: Self.configKey)
    }

    public func delete() {
        defaults.removeObject(forKey: Self.configKey)
    }
}

// MARK: - Errors

public enum LocalFormattingModelError: Error, LocalizedError, Sendable {
    case notConfigured
    case cliNotFound(String)
    case timeout(seconds: Double)
    case nonZeroExit(code: Int32, stderr: String)
    case emptyOutput
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Local Formatting Model is not configured. Set the cleanup CLI path in Settings."
        case .cliNotFound(let path):
            return "Cleanup CLI not found at: \(path)"
        case .timeout(let seconds):
            return "Cleanup CLI timed out after \(Int(seconds)) seconds."
        case .nonZeroExit(let code, let stderr):
            if stderr.isEmpty {
                return "Cleanup CLI failed with exit code \(code)."
            }
            return "Cleanup CLI failed (exit \(code)): \(stderr)"
        case .emptyOutput:
            return "Cleanup CLI returned empty output."
        case .executionFailed(let detail):
            return "Failed to run cleanup CLI: \(detail)"
        }
    }
}

// MARK: - Executor

public final class LocalFormattingModelExecutor: Sendable {
    public init() {}

    /// Run the cleanup CLI. The system prompt (template, possibly containing
    /// `{{TRANSCRIPT}}`) is written to a temp file and passed via
    /// `--prompt-file`. The transcript is piped on stdin so it never touches
    /// the argv length limit.
    public func execute(
        systemPrompt: String,
        transcript: String,
        config: LocalFormattingModelConfig
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runProcess(
                        systemPrompt: systemPrompt,
                        transcript: transcript,
                        config: config
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func testConnection(config: LocalFormattingModelConfig) async throws {
        let output = try await execute(
            systemPrompt: "",
            transcript: "hello world",
            config: config
        )
        guard !output.isEmpty else {
            throw LocalFormattingModelError.emptyOutput
        }
    }

    /// Fire-and-forget warm-up. Invokes the cleanup CLI with `--warmup`, which
    /// asks the daemon to start loading the MLX model in the background and
    /// exits immediately. Safe to call repeatedly — the CLI no-ops if the
    /// daemon is already warm.
    public func warmUp(config: LocalFormattingModelConfig) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try Self.runWarmup(config: config)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runWarmup(config: LocalFormattingModelConfig) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        let resolvedCLIPath = config.resolvedCLIPath()
        let commandParts = [
            shellEscape(resolvedCLIPath),
            "--warmup",
            "--mode", config.mode.rawValue,
            "--model", shellEscape(config.modelID),
        ]
        process.arguments = ["-lc", commandParts.joined(separator: " ")]

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(existing):\(extraPath)"
        } else {
            env["PATH"] = extraPath
        }
        process.environment = env

        // Discard stdout/stderr — warm-up output is debug-only.
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw LocalFormattingModelError.executionFailed(error.localizedDescription)
        }
        process.waitUntilExit()
    }

    // MARK: - Private

    private static func runProcess(
        systemPrompt: String,
        transcript: String,
        config: LocalFormattingModelConfig
    ) throws -> String {
        let process = Process()
        let executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.executableURL = executableURL

        // Write the system prompt (verbatim, may contain {{TRANSCRIPT}}) to a
        // temp file. The CLI will substitute the placeholder in LLM mode and
        // ignore it in rules mode.
        let promptFileURL: URL?
        if !systemPrompt.isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("macparakeet-cleanup-prompt-\(UUID().uuidString).txt")
            try systemPrompt.write(to: url, atomically: true, encoding: .utf8)
            promptFileURL = url
        } else {
            promptFileURL = nil
        }

        defer {
            if let promptFileURL { try? FileManager.default.removeItem(at: promptFileURL) }
        }

        let resolvedCLIPath = config.resolvedCLIPath()
        var commandParts = [
            shellEscape(resolvedCLIPath),
            "--mode", config.mode.rawValue,
            "--model", shellEscape(config.modelID),
            "--timeout", String(config.timeoutSeconds),
        ]
        if let promptFileURL {
            commandParts.append(contentsOf: ["--prompt-file", shellEscape(promptFileURL.path)])
        }
        let command = commandParts.joined(separator: " ")

        process.arguments = ["-lc", command]

        // Inherit env but ensure PATH includes common locations for `python`
        // and the cleanup script.
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(existing):\(extraPath)"
        } else {
            env["PATH"] = extraPath
        }
        process.environment = env

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw LocalFormattingModelError.executionFailed(error.localizedDescription)
        }

        // Write transcript on stdin and close.
        if let data = transcript.data(using: .utf8) {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? inputPipe.fileHandleForWriting.close()

        // Read stdout/stderr concurrently to avoid pipe-buffer deadlock.
        let stdoutCapture = DataBox()
        let stderrCapture = DataBox()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutCapture.set((try? outputPipe.fileHandleForReading.readToEnd()) ?? Data())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCapture.set((try? errorPipe.fileHandleForReading.readToEnd()) ?? Data())
            readGroup.leave()
        }

        let semaphore = DispatchSemaphore(value: 0)
        let terminationStatus = TerminationBox()
        process.terminationHandler = { proc in
            terminationStatus.set(proc.terminationStatus)
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + config.timeoutSeconds + 5)
        if waitResult == .timedOut {
            if process.isRunning {
                kill(process.processIdentifier, SIGTERM)
                _ = semaphore.wait(timeout: .now() + 1)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            _ = readGroup.wait(timeout: .now() + 1)
            throw LocalFormattingModelError.timeout(seconds: config.timeoutSeconds)
        }

        _ = readGroup.wait(timeout: .now() + 2)

        let stdout = String(data: stdoutCapture.get(), encoding: .utf8) ?? ""
        let stderr = (String(data: stderrCapture.get(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let exitCode = terminationStatus.get() ?? 0

        if exitCode != 0 {
            let lower = stderr.lowercased()
            if exitCode == 127 || lower.contains("command not found") || lower.contains("no such file") {
                throw LocalFormattingModelError.cliNotFound(resolvedCLIPath)
            }
            throw LocalFormattingModelError.nonZeroExit(code: exitCode, stderr: stderr)
        }

        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw LocalFormattingModelError.emptyOutput
        }
        return stdout
    }

    static func shellEscape(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-./:="))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ data: Data) { lock.withLock { value = data } }
        func get() -> Data { lock.withLock { value } }
    }

    private final class TerminationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        func set(_ status: Int32) { lock.withLock { value = status } }
        func get() -> Int32? { lock.withLock { value } }
    }
}

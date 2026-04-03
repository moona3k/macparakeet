import Foundation
import os

// MARK: - Configuration

public struct LocalCLIConfig: Codable, Sendable, Equatable {
    public let commandTemplate: String
    public let timeoutSeconds: Double

    public static let defaultTimeout: Double = 120

    public init(commandTemplate: String, timeoutSeconds: Double = Self.defaultTimeout) {
        self.commandTemplate = commandTemplate
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - Templates

public enum LocalCLITemplate: String, CaseIterable, Sendable, Codable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    public var defaultCommand: String {
        switch self {
        case .claudeCode: return "claude -p"
        case .codex: return "codex exec"
        }
    }

    public var defaultConfig: LocalCLIConfig {
        LocalCLIConfig(commandTemplate: defaultCommand)
    }
}

// MARK: - Errors

public enum LocalCLIError: Error, LocalizedError, Sendable {
    case commandNotConfigured
    case commandNotFound(String)
    case timeout(seconds: Double)
    case nonZeroExit(code: Int32, stderr: String)
    case emptyOutput
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandNotConfigured:
            return "Local CLI command is not configured. Choose a template or enter a command in Settings."
        case .commandNotFound(let details):
            return "CLI command not found. Ensure it is installed and on your PATH. Details: \(details)"
        case .timeout(let seconds):
            return "CLI command timed out after \(Int(seconds)) seconds."
        case .nonZeroExit(let code, let stderr):
            if stderr.isEmpty {
                return "CLI command failed with exit code \(code)."
            }
            return "CLI command failed (exit \(code)): \(stderr)"
        case .emptyOutput:
            return "CLI command returned empty output."
        case .executionFailed(let message):
            return "Failed to run CLI command: \(message)"
        }
    }
}

// MARK: - Config Store

public final class LocalCLIConfigStore: @unchecked Sendable {
    private static let configKey = "local_cli_config"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> LocalCLIConfig? {
        guard let data = defaults.data(forKey: Self.configKey) else { return nil }
        return try? JSONDecoder().decode(LocalCLIConfig.self, from: data)
    }

    public func save(_ config: LocalCLIConfig) throws {
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: Self.configKey)
    }

    public func delete() {
        defaults.removeObject(forKey: Self.configKey)
    }
}

// MARK: - Executor

public final class LocalCLIExecutor: Sendable {
    private let configStore: LocalCLIConfigStore
    private let cachedPATH: OSAllocatedUnfairLock<String?>

    public init(configStore: LocalCLIConfigStore = LocalCLIConfigStore()) {
        self.configStore = configStore
        self.cachedPATH = OSAllocatedUnfairLock(initialState: nil)
    }

    /// Execute a CLI command with the given prompt components.
    /// - Parameters:
    ///   - systemPrompt: System-level instructions for the LLM.
    ///   - userPrompt: User-facing prompt content.
    ///   - config: Optional override config; reads from store if nil.
    /// - Returns: The CLI's stdout output, trimmed.
    public func execute(
        systemPrompt: String,
        userPrompt: String,
        config: LocalCLIConfig? = nil
    ) async throws -> String {
        let resolvedConfig = try resolveConfig(config)
        let fullPrompt = Self.formatFullPrompt(system: systemPrompt, user: userPrompt)

        return try await runProcess(
            commandTemplate: resolvedConfig.commandTemplate,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt,
            timeout: resolvedConfig.timeoutSeconds
        )
    }

    /// Quick test: runs the configured command with a minimal prompt.
    public func testConnection(config: LocalCLIConfig? = nil) async throws {
        let output = try await execute(
            systemPrompt: "You are a helpful assistant.",
            userPrompt: "Reply with OK",
            config: config
        )
        guard !output.isEmpty else {
            throw LocalCLIError.emptyOutput
        }
    }

    // MARK: - Prompt Formatting

    static func formatFullPrompt(system: String, user: String) -> String {
        if system.isEmpty {
            return user
        }
        return """
            \(system)

            ---

            \(user)
            """
    }

    // MARK: - Private

    private func resolveConfig(_ override: LocalCLIConfig?) throws -> LocalCLIConfig {
        if let override { return override }
        guard let stored = configStore.load() else {
            throw LocalCLIError.commandNotConfigured
        }
        guard !stored.commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalCLIError.commandNotConfigured
        }
        return stored
    }

    private func runProcess(
        commandTemplate: String,
        systemPrompt: String,
        userPrompt: String,
        fullPrompt: String,
        timeout: Double
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Run on a background queue — Process APIs are synchronous
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", commandTemplate]

                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = preferredPATH(fallback: environment["PATH"])
                environment["MACPARAKEET_SYSTEM_PROMPT"] = systemPrompt
                environment["MACPARAKEET_USER_PROMPT"] = userPrompt
                environment["MACPARAKEET_FULL_PROMPT"] = fullPrompt
                process.environment = environment

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: LocalCLIError.executionFailed(error.localizedDescription))
                    return
                }

                // Write prompt to stdin so CLI tools can read it
                if let data = fullPrompt.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(data)
                }
                try? inputPipe.fileHandleForWriting.close()

                // Wait for process with timeout
                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in
                    semaphore.signal()
                }

                let waitResult = semaphore.wait(timeout: .now() + timeout)
                if waitResult == .timedOut {
                    if process.isRunning { process.terminate() }
                    // Give it a moment to clean up
                    _ = semaphore.wait(timeout: .now() + 2)
                    continuation.resume(throwing: LocalCLIError.timeout(seconds: timeout))
                    return
                }

                let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = (String(data: stdoutData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let exitCode = process.terminationStatus
                if exitCode != 0 {
                    let looksLikeNotFound = exitCode == 127 || stderr.lowercased().contains("command not found")
                    if looksLikeNotFound {
                        continuation.resume(throwing: LocalCLIError.commandNotFound(
                            stderr.isEmpty ? commandTemplate : stderr
                        ))
                    } else {
                        continuation.resume(throwing: LocalCLIError.nonZeroExit(code: exitCode, stderr: stderr))
                    }
                    return
                }

                guard !stdout.isEmpty else {
                    continuation.resume(throwing: LocalCLIError.emptyOutput)
                    return
                }

                continuation.resume(returning: stdout)
            }
        }
    }

    // MARK: - PATH Discovery

    /// Returns the user's full shell PATH. Apps launched from Finder/Dock
    /// inherit a minimal PATH that lacks Homebrew, nvm, etc.
    private func preferredPATH(fallback: String?) -> String {
        if let cached = cachedPATH.withLock({ $0 }) {
            return cached
        }

        if let discovered = Self.discoverPATH() {
            cachedPATH.withLock { $0 = discovered }
            return discovered
        }

        return fallback ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    }

    /// Spawns an interactive login shell to capture the user's PATH.
    private static func discoverPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-ilc",
            "echo __MACPARAKEET_PATH_START__; print -r -- $PATH; echo __MACPARAKEET_PATH_END__",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        let waitResult = semaphore.wait(timeout: .now() + 3)
        if waitResult == .timedOut {
            if process.isRunning { process.terminate() }
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let startMarker = "__MACPARAKEET_PATH_START__"
        let endMarker = "__MACPARAKEET_PATH_END__"

        guard let startRange = output.range(of: startMarker),
              let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex)
        else {
            return nil
        }

        let path = output[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return path.isEmpty ? nil : path
    }
}

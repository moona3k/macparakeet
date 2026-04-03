import Foundation
import Darwin
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

// @unchecked Sendable: UserDefaults is internally thread-safe
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
    private final class ProcessExecutionState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var continuationResumed = false

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func setProcess(_ process: Process) -> Bool {
            lock.withLock {
                self.process = process
                return cancelled
            }
        }

        func cancel() -> Process? {
            lock.withLock {
                cancelled = true
                return process
            }
        }

        func claimContinuation() -> Bool {
            lock.withLock {
                guard !continuationResumed else { return false }
                continuationResumed = true
                return true
            }
        }
    }

    private let cachedPATH: OSAllocatedUnfairLock<String?>

    public init() {
        self.cachedPATH = OSAllocatedUnfairLock(initialState: nil)
    }

    /// Execute a CLI command with the given prompt components.
    /// - Parameters:
    ///   - systemPrompt: System-level instructions for the LLM.
    ///   - userPrompt: User-facing prompt content.
    ///   - config: Explicit CLI execution configuration.
    /// - Returns: The CLI's stdout output, trimmed.
    public func execute(
        systemPrompt: String,
        userPrompt: String,
        config: LocalCLIConfig
    ) async throws -> String {
        let fullPrompt = Self.formatFullPrompt(system: systemPrompt, user: userPrompt)

        return try await runProcess(
            commandTemplate: config.commandTemplate,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt,
            timeout: config.timeoutSeconds
        )
    }

    /// Quick test: runs the configured command with a minimal prompt.
    public func testConnection(config: LocalCLIConfig) async throws {
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

    private func runProcess(
        commandTemplate: String,
        systemPrompt: String,
        userPrompt: String,
        fullPrompt: String,
        timeout: Double
    ) async throws -> String {
        let clampedTimeout = max(5, timeout)
        let state = ProcessExecutionState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                // Run on a background queue — Process APIs are synchronous
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    if state.isCancelled {
                        Self.resume(continuation, state: state, result: .failure(CancellationError()))
                        return
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", commandTemplate]

                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = preferredPATH(fallback: environment["PATH"])
                    // Env vars are capped to avoid hitting macOS exec arg+env size limits
                    // (~256KB). Full prompt content is always available via stdin.
                    let envLimit = 32_000
                    environment["MACPARAKEET_SYSTEM_PROMPT"] = String(systemPrompt.prefix(envLimit))
                    environment["MACPARAKEET_USER_PROMPT"] = String(userPrompt.prefix(envLimit))
                    environment["MACPARAKEET_FULL_PROMPT"] = String(fullPrompt.prefix(envLimit))
                    process.environment = environment

                    let inputPipe = Pipe()
                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardInput = inputPipe
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    // Install termination handler BEFORE run() to avoid race
                    // where a fast command exits before the handler is set.
                    let semaphore = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in
                        semaphore.signal()
                    }

                    if state.setProcess(process) {
                        Self.resume(continuation, state: state, result: .failure(CancellationError()))
                        return
                    }

                    do {
                        try process.run()
                    } catch {
                        let failure: Error = state.isCancelled
                            ? CancellationError()
                            : LocalCLIError.executionFailed(error.localizedDescription)
                        Self.resume(continuation, state: state, result: .failure(failure))
                        return
                    }

                    // Read stdout/stderr concurrently with process execution to
                    // avoid pipe deadlock: if the pipe buffer fills (64KB), the
                    // process blocks writing and can never exit.
                    var stdoutData = Data()
                    var stderrData = Data()
                    let readGroup = DispatchGroup()

                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stdoutData = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
                        readGroup.leave()
                    }
                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stderrData = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
                        readGroup.leave()
                    }

                    let writerGroup = DispatchGroup()
                    writerGroup.enter()
                    let promptData = fullPrompt.data(using: .utf8) ?? Data()
                    DispatchQueue.global(qos: .utility).async {
                        Self.writePromptData(
                            promptData,
                            to: inputPipe.fileHandleForWriting,
                            isCancelled: { state.isCancelled }
                        )
                        try? inputPipe.fileHandleForWriting.close()
                        writerGroup.leave()
                    }

                    // Wait for process with timeout while stdin is written on a
                    // separate queue so a full pipe cannot block timeout/cancel.
                    let waitResult = semaphore.wait(timeout: .now() + clampedTimeout)
                    if waitResult == .timedOut {
                        Self.stopProcess(process)
                        _ = semaphore.wait(timeout: .now() + 2)
                        Self.closePipes(
                            input: inputPipe.fileHandleForWriting,
                            output: outputPipe.fileHandleForReading,
                            error: errorPipe.fileHandleForReading
                        )
                        _ = writerGroup.wait(timeout: .now() + 1)
                        _ = readGroup.wait(timeout: .now() + 1)
                        Self.resume(
                            continuation,
                            state: state,
                            result: .failure(LocalCLIError.timeout(seconds: clampedTimeout))
                        )
                        return
                    }

                    if state.isCancelled {
                        Self.closePipes(
                            input: inputPipe.fileHandleForWriting,
                            output: outputPipe.fileHandleForReading,
                            error: errorPipe.fileHandleForReading
                        )
                        _ = writerGroup.wait(timeout: .now() + 1)
                        _ = readGroup.wait(timeout: .now() + 1)
                        Self.resume(continuation, state: state, result: .failure(CancellationError()))
                        return
                    }

                    _ = writerGroup.wait(timeout: .now() + 1)
                    readGroup.wait()

                    if state.isCancelled {
                        Self.resume(continuation, state: state, result: .failure(CancellationError()))
                        return
                    }

                    let stdout = (String(data: stdoutData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    let exitCode = process.terminationStatus
                    if exitCode != 0 {
                        let looksLikeNotFound = exitCode == 127 || stderr.lowercased().contains("command not found")
                        if looksLikeNotFound {
                            Self.resume(
                                continuation,
                                state: state,
                                result: .failure(LocalCLIError.commandNotFound(
                                    stderr.isEmpty ? commandTemplate : stderr
                                ))
                            )
                        } else {
                            Self.resume(
                                continuation,
                                state: state,
                                result: .failure(LocalCLIError.nonZeroExit(code: exitCode, stderr: stderr))
                            )
                        }
                        return
                    }

                    guard !stdout.isEmpty else {
                        Self.resume(continuation, state: state, result: .failure(LocalCLIError.emptyOutput))
                        return
                    }

                    Self.resume(continuation, state: state, result: .success(stdout))
                }
            }
        } onCancel: {
            if let process = state.cancel() {
                Self.stopProcess(process)
            }
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<String, Error>,
        state: ProcessExecutionState,
        result: Result<String, Error>
    ) {
        guard state.claimContinuation() else { return }
        switch result {
        case .success(let output):
            continuation.resume(returning: output)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static func writePromptData(
        _ data: Data,
        to handle: FileHandle,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        guard !data.isEmpty else { return }
        let fileDescriptor = handle.fileDescriptor
        _ = Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)

        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            var offset = 0
            while offset < data.count {
                if isCancelled() { break }

                let chunkSize = min(16_384, data.count - offset)
                let pointer = baseAddress.advanced(by: offset)
                let written = Darwin.write(fileDescriptor, pointer, chunkSize)

                if written > 0 {
                    offset += written
                    continue
                }

                if written == -1 && errno == EINTR {
                    continue
                }

                break
            }
        }
    }

    private static func stopProcess(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()
        usleep(200_000)

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func closePipes(input: FileHandle, output: FileHandle, error: FileHandle) {
        try? input.close()
        try? output.close()
        try? error.close()
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

    /// Spawns a login shell to capture the user's PATH.
    /// Uses `-lc` (login, non-interactive) to source .zprofile/.zlogin
    /// without triggering interactive .zshrc hooks that could hang.
    private static func discoverPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "echo __MACPARAKEET_PATH_START__; print -r -- $PATH; echo __MACPARAKEET_PATH_END__",
        ]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Discard stderr to avoid pipe deadlock from noisy shell profiles
        process.standardError = FileHandle.nullDevice

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

        let output = String(data: (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
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

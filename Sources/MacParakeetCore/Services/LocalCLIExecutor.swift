import Foundation
import Darwin
import os

// MARK: - Configuration

public struct LocalCLIConfig: Codable, Sendable, Equatable {
    public let commandTemplate: String
    public let timeoutSeconds: Double

    public static let minimumTimeout: Double = 5
    public static let defaultTimeout: Double = 120

    public init(commandTemplate: String, timeoutSeconds: Double = Self.defaultTimeout) {
        self.commandTemplate = commandTemplate
        self.timeoutSeconds = max(Self.minimumTimeout, timeoutSeconds)
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
        case .claudeCode: return "claude -p --model haiku"
        case .codex: return "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        }
    }

    public var defaultConfig: LocalCLIConfig {
        LocalCLIConfig(commandTemplate: defaultCommand)
    }

    public static func inferredTemplate(for commandTemplate: String) -> LocalCLITemplate? {
        let trimmed = commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "claude" || trimmed.hasPrefix("claude ") {
            return .claudeCode
        }
        if trimmed == "codex" || trimmed.hasPrefix("codex ") {
            return .codex
        }
        return nil
    }

    public static func displayName(for commandTemplate: String) -> String {
        inferredTemplate(for: commandTemplate)?.displayName ?? "Custom CLI"
    }
}

// MARK: - Errors

public enum LocalCLIError: Error, LocalizedError, Sendable {
    case commandNotConfigured
    case commandNotFound(String)
    case timeout(seconds: Double)
    case drainTimeout
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
        case .drainTimeout:
            return "CLI command exited, but its output pipes did not close in time."
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
    private static let outputDrainTimeout: Double = 2
    private static let processTreeWarmupPollCount = 40
    private static let processTreeWarmupPollIntervalUs: useconds_t = 5_000
    private static let processTreePollIntervalUs: useconds_t = 50_000

    private final class ProcessExecutionState: @unchecked Sendable {
        private let lock = NSLock()
        private var processID: Int32?
        private var cancelled = false
        private var continuationResumed = false
        private var monitoringStopped = false
        private var observedDescendantPIDs = Set<Int32>()

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func setProcessID(_ processID: Int32) -> Bool {
            lock.withLock {
                self.processID = processID
                return cancelled
            }
        }

        func cancel() -> Int32? {
            lock.withLock {
                cancelled = true
                return processID
            }
        }

        func claimContinuation() -> Bool {
            lock.withLock {
                guard !continuationResumed else { return false }
                continuationResumed = true
                return true
            }
        }

        func stopMonitoring() {
            lock.withLock {
                monitoringStopped = true
            }
        }

        func shouldMonitor(processID: Int32) -> Bool {
            lock.withLock {
                !monitoringStopped && self.processID == processID
            }
        }

        func recordObservedDescendants(_ pids: [Int32]) {
            guard !pids.isEmpty else { return }
            lock.withLock {
                observedDescendantPIDs.formUnion(pids.filter { $0 > 0 })
            }
        }

        func observedDescendants() -> [Int32] {
            lock.withLock { Array(observedDescendantPIDs) }
        }
    }

    private final class ChildTerminationState: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?

        func setStatus(_ status: Int32) {
            lock.withLock {
                self.status = status
            }
        }

        func currentStatus() -> Int32? {
            lock.withLock { status }
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

    static func wrappedCommandTemplate(_ commandTemplate: String) -> String {
        """
        __macparakeet_cleanup_children() {
            local children
            children=$(pgrep -P $$)
            if [ -n "$children" ]; then
                kill $children >/dev/null 2>&1 || true
                sleep 0.2
                kill -9 $children >/dev/null 2>&1 || true
            fi
        }
        trap '__macparakeet_cleanup_children; trap - TERM INT; exit 143' TERM INT
        \(commandTemplate)
        __macparakeet_exit_code=$?
        __macparakeet_cleanup_children
        exit $__macparakeet_exit_code
        """
    }

    static func executionWorkingDirectory(fileManager: FileManager = .default) throws -> URL {
        let appSupportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let workingDirectory = appSupportDirectory
            .appendingPathComponent("MacParakeet", isDirectory: true)
            .appendingPathComponent("LocalCLI", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return workingDirectory
    }

    // MARK: - Private

    private func runProcess(
        commandTemplate: String,
        systemPrompt: String,
        userPrompt: String,
        fullPrompt: String,
        timeout: Double
    ) async throws -> String {
        let clampedTimeout = max(LocalCLIConfig.minimumTimeout, timeout)
        let state = ProcessExecutionState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                // Run on a background queue — Process APIs are synchronous
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    if state.isCancelled {
                        Self.resume(continuation, state: state, result: .failure(CancellationError()))
                        return
                    }

                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = preferredPATH(fallback: environment["PATH"])
                    // Env vars are capped to avoid hitting macOS exec arg+env size limits
                    // (~256KB). Full prompt content is always available via stdin.
                    let envLimit = 32_000
                    environment["MACPARAKEET_SYSTEM_PROMPT"] = String(systemPrompt.prefix(envLimit))
                    environment["MACPARAKEET_USER_PROMPT"] = String(userPrompt.prefix(envLimit))
                    environment["MACPARAKEET_FULL_PROMPT"] = String(fullPrompt.prefix(envLimit))

                    let inputPipe = Pipe()
                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    let semaphore = DispatchSemaphore(value: 0)
                    let terminationState = ChildTerminationState()
                    let processID: Int32

                    do {
                        processID = try Self.spawnShell(
                            command: Self.wrappedCommandTemplate(commandTemplate),
                            environment: environment,
                            inputPipe: inputPipe,
                            outputPipe: outputPipe,
                            errorPipe: errorPipe
                        )
                    } catch {
                        let failure: Error = state.isCancelled
                            ? CancellationError()
                            : LocalCLIError.executionFailed(error.localizedDescription)
                        Self.resume(continuation, state: state, result: .failure(failure))
                        return
                    }

                    if state.setProcessID(processID) {
                        Self.stopProcess(processID, state: state)
                        Self.resume(continuation, state: state, result: .failure(CancellationError()))
                        return
                    }

                    DispatchQueue.global(qos: .utility).async {
                        var status: Int32 = 0
                        while waitpid(processID, &status, 0) == -1 {
                            if errno == EINTR {
                                continue
                            }
                            break
                        }
                        terminationState.setStatus(status)
                        semaphore.signal()
                    }

                    let monitorGroup = DispatchGroup()
                    monitorGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        Self.monitorDescendants(of: processID, state: state)
                        monitorGroup.leave()
                    }
                    defer {
                        state.stopMonitoring()
                        _ = monitorGroup.wait(timeout: .now() + 1)
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
                        Self.stopProcess(processID, state: state)
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
                        Self.stopProcess(processID, state: state)
                        _ = writerGroup.wait(timeout: .now() + 1)
                        _ = readGroup.wait(timeout: .now() + 1)
                        Self.resume(continuation, state: state, result: .failure(CancellationError()))
                        return
                    }

                    _ = writerGroup.wait(timeout: .now() + 1)
                    let drainWaitResult = readGroup.wait(timeout: .now() + Self.outputDrainTimeout)
                    if drainWaitResult == .timedOut {
                        Self.closePipes(
                            input: inputPipe.fileHandleForWriting,
                            output: outputPipe.fileHandleForReading,
                            error: errorPipe.fileHandleForReading
                        )
                        Self.stopProcess(processID, state: state)
                        _ = readGroup.wait(timeout: .now() + 1)
                        Self.resume(
                            continuation,
                            state: state,
                            result: .failure(LocalCLIError.drainTimeout)
                        )
                        return
                    }

                    if state.isCancelled {
                        Self.stopProcess(processID, state: state)
                        Self.resume(continuation, state: state, result: .failure(CancellationError()))
                        return
                    }

                    Self.stopProcess(processID, state: state)

                    let stdout = (String(data: stdoutData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    let exitCode = Self.exitCode(from: terminationState.currentStatus() ?? 0)
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
            if let processID = state.cancel() {
                Self.stopProcess(processID, state: state)
            }
        }
    }

    private static func spawnShell(
        command: String,
        environment: [String: String],
        inputPipe: Pipe,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) throws -> Int32 {
        let executable = "/bin/zsh"
        let arguments = [executable, "-lc", command]
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        let workingDirectory = try executionWorkingDirectory()

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw LocalCLIError.executionFailed("Unable to initialize file actions")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let stdinRead = inputPipe.fileHandleForReading.fileDescriptor
        let stdinWrite = inputPipe.fileHandleForWriting.fileDescriptor
        let stdoutRead = outputPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = outputPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = errorPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = errorPipe.fileHandleForWriting.fileDescriptor

        let configuredFileActions = workingDirectory.withUnsafeFileSystemRepresentation { workingDirectoryPath in
            guard let workingDirectoryPath else { return false }
            return addChangeDirectoryAction(&fileActions, path: workingDirectoryPath) &&
                posix_spawn_file_actions_adddup2(&fileActions, stdinRead, STDIN_FILENO) == 0 &&
                posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO) == 0 &&
                posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO) == 0 &&
                posix_spawn_file_actions_addclose(&fileActions, stdinWrite) == 0 &&
                posix_spawn_file_actions_addclose(&fileActions, stdoutRead) == 0 &&
                posix_spawn_file_actions_addclose(&fileActions, stderrRead) == 0 &&
                posix_spawn_file_actions_addclose(&fileActions, stdinRead) == 0 &&
                posix_spawn_file_actions_addclose(&fileActions, stdoutWrite) == 0 &&
                posix_spawn_file_actions_addclose(&fileActions, stderrWrite) == 0
        }
        guard configuredFileActions else {
            throw LocalCLIError.executionFailed("Unable to configure spawn file actions")
        }

        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else {
            throw LocalCLIError.executionFailed("Unable to initialize spawn attributes")
        }
        defer { posix_spawnattr_destroy(&attr) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attr, flags) == 0,
              posix_spawnattr_setpgroup(&attr, 0) == 0
        else {
            throw LocalCLIError.executionFailed("Unable to configure spawn process group")
        }

        var pid = pid_t()
        let spawnResult = try withSpawnCStringArray(arguments) { argv in
            try withSpawnCStringArray(environmentStrings) { envp in
                posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)
            }
        }
        guard spawnResult == 0 else {
            throw LocalCLIError.executionFailed(String(cString: strerror(spawnResult)))
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        return pid
    }

    private static func addChangeDirectoryAction(
        _ fileActions: inout posix_spawn_file_actions_t?,
        path: UnsafePointer<CChar>
    ) -> Bool {
        if #available(macOS 26.0, *) {
            return posix_spawn_file_actions_addchdir(&fileActions, path) == 0
        }
        return posix_spawn_file_actions_addchdir_np(&fileActions, path) == 0
    }

    private static func withSpawnCStringArray<R>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> R
    ) throws -> R {
        let cStrings = try strings.map { string -> UnsafeMutablePointer<CChar>? in
            guard let duplicated = strdup(string) else {
                throw LocalCLIError.executionFailed("Unable to allocate spawn argument")
            }
            return duplicated
        }
        defer {
            cStrings.forEach { free($0) }
        }

        var pointerArray = cStrings + [nil]
        return try pointerArray.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let statusBits = waitStatus & 0x7f
        if statusBits == 0 {
            return (waitStatus >> 8) & 0xff
        }
        if statusBits != 0x7f {
            return 128 + statusBits
        }
        return waitStatus
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

    private static func stopProcess(_ processID: Int32, state: ProcessExecutionState? = nil) {
        state?.stopMonitoring()

        signalProcessGroup(processID, signal: SIGTERM)
        signalProcesses(descendantProcessIDs(of: processID) + (state?.observedDescendants() ?? []), signal: SIGTERM)
        usleep(200_000)

        signalProcessGroup(processID, signal: SIGKILL)
        signalProcesses(descendantProcessIDs(of: processID) + (state?.observedDescendants() ?? []), signal: SIGKILL)
        kill(processID, SIGKILL)
    }

    private static func stopObservedDescendants(from state: ProcessExecutionState) {
        state.stopMonitoring()
        signalProcesses(state.observedDescendants(), signal: SIGTERM)
        usleep(200_000)
        signalProcesses(state.observedDescendants(), signal: SIGKILL)
    }

    private static func closePipes(input: FileHandle, output: FileHandle, error: FileHandle) {
        try? input.close()
        try? output.close()
        try? error.close()
    }

    private static func monitorDescendants(of rootPID: Int32, state: ProcessExecutionState) {
        var pollCount = 0
        while state.shouldMonitor(processID: rootPID) {
            state.recordObservedDescendants(descendantProcessIDs(of: rootPID))
            let interval = pollCount < Self.processTreeWarmupPollCount
                ? Self.processTreeWarmupPollIntervalUs
                : Self.processTreePollIntervalUs
            usleep(interval)
            pollCount += 1
        }
    }

    private static func descendantProcessIDs(of rootPID: Int32) -> [Int32] {
        guard rootPID > 0 else { return [] }

        var seen = Set<Int32>()
        var queue = directChildProcessIDs(of: rootPID)

        while let pid = queue.popLast() {
            guard pid > 0, seen.insert(pid).inserted else { continue }
            queue.append(contentsOf: directChildProcessIDs(of: pid))
        }

        return Array(seen)
    }

    private static func directChildProcessIDs(of parentPID: Int32) -> [Int32] {
        guard parentPID > 0 else { return [] }

        let pidSize = MemoryLayout<Int32>.stride
        var capacity = 16

        while true {
            var buffer = Array(repeating: Int32.zero, count: capacity)
            let bytesReturned = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                proc_listchildpids(parentPID, rawBuffer.baseAddress, Int32(rawBuffer.count))
            }

            guard bytesReturned > 0 else { return [] }

            let count = Int(bytesReturned) / pidSize
            guard count > 0 else { return [] }

            if count < capacity {
                return Array(buffer.prefix(count))
            }

            capacity *= 2
        }
    }

    private static func signalProcesses(_ pids: [Int32], signal: Int32) {
        for pid in Set(pids) where pid > 0 {
            _ = kill(pid, signal)
        }
    }

    private static func signalProcessGroup(_ processID: Int32, signal: Int32) {
        guard processID > 0 else { return }
        _ = kill(-processID, signal)
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
    static func discoverPATH(
        executableURL: URL = URL(fileURLWithPath: "/bin/zsh"),
        arguments: [String] = [
            "-lc",
            "echo __MACPARAKEET_PATH_START__; print -r -- $PATH; echo __MACPARAKEET_PATH_END__",
        ],
        timeout: Double = 3
    ) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

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

        var outputData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            readGroup.leave()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if process.isRunning {
                Self.stopProcess(process.processIdentifier)
            }
            Self.closePipes(
                input: FileHandle.nullDevice,
                output: stdoutPipe.fileHandleForReading,
                error: FileHandle.nullDevice
            )
            _ = readGroup.wait(timeout: .now() + 1)
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        guard readGroup.wait(timeout: .now() + 1) == .success else { return nil }

        let output = String(data: outputData, encoding: .utf8) ?? ""
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

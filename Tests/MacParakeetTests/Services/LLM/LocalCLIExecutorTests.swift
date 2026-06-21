import XCTest
@testable import MacParakeetCore

final class LocalCLIExecutorTests: XCTestCase {
    private static let standardPATHProbeShellPaths = [
        "/bin/zsh",
        "/opt/homebrew/bin/zsh",
        "/usr/local/bin/zsh",
        "/bin/bash",
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
        "/opt/homebrew/bin/fish",
        "/usr/local/bin/fish",
        "/usr/bin/fish",
        "/bin/sh",
    ]

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func createExecutable(at url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func isProcessRunning(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func waitForFiles(_ paths: [String], timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    private func waitForTaskCompletionAfterCancel(
        _ task: Task<String, Error>,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let didFinish = await group.next() ?? false
            group.cancelAll()
            return didFinish
        }
    }

    // MARK: - Config Store

    func testConfigStoreRoundTrip() throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)

        XCTAssertNil(store.load())

        let config = LocalCLIConfig(commandTemplate: "claude -p --model haiku", timeoutSeconds: 90)
        try store.save(config)

        let loaded = store.load()
        XCTAssertEqual(loaded, config)

        store.delete()
        XCTAssertNil(store.load())
    }

    func testDefaultTimeoutAndTimeoutDescription() {
        XCTAssertEqual(LocalCLIConfig.defaultTimeout, 300)
        XCTAssertEqual(LocalCLIConfig.legacyDefaultTimeout, 45)
        XCTAssertEqual(
            LocalCLIError.timeout(seconds: LocalCLIConfig.defaultTimeout).errorDescription,
            "Timed out after 300s. Verify the command runs successfully in a terminal and is logged in if required."
        )
    }

    func testConfigStoreMigratesLegacyDefaultTimeoutOnFirstLoad() throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)

        // Simulate a pre-#478 store: a config saved with the old 45s default,
        // never loaded under the new version.
        try store.save(
            LocalCLIConfig(commandTemplate: "codex exec --skip-git-repo-check", timeoutSeconds: 45)
        )

        let migrated = store.load()
        XCTAssertEqual(migrated?.timeoutSeconds, LocalCLIConfig.defaultTimeout)
        XCTAssertEqual(migrated?.commandTemplate, "codex exec --skip-git-repo-check")

        // The migrated value is persisted, not just returned.
        XCTAssertEqual(store.load()?.timeoutSeconds, LocalCLIConfig.defaultTimeout)

        // 45 entered after the migration is an explicit choice and sticks.
        try store.save(
            LocalCLIConfig(commandTemplate: "codex exec --skip-git-repo-check", timeoutSeconds: 45)
        )
        XCTAssertEqual(store.load()?.timeoutSeconds, 45)
    }

    func testConfigStoreDoesNotMigrateNonDefaultLegacyTimeout() throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)

        try store.save(
            LocalCLIConfig(commandTemplate: "claude -p --model haiku", timeoutSeconds: 60)
        )

        XCTAssertEqual(store.load()?.timeoutSeconds, 60)
    }

    func testConfigStoreEmptyLoadConsumesMigrationWindow() throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)

        // A load with no stored config marks the store as post-#478: a 45
        // saved afterwards was typed under the new default and is preserved.
        XCTAssertNil(store.load())
        try store.save(
            LocalCLIConfig(commandTemplate: "claude -p --model haiku", timeoutSeconds: 45)
        )
        XCTAssertEqual(store.load()?.timeoutSeconds, 45)
    }

    func testTestConnectionConfigCapsTimeout() {
        let slow = LocalCLIConfig(commandTemplate: "codex exec", timeoutSeconds: 300)
        XCTAssertEqual(
            LocalCLIExecutor.testConnectionConfig(for: slow).timeoutSeconds,
            LocalCLIExecutor.testConnectionTimeoutCap
        )

        let fast = LocalCLIConfig(commandTemplate: "codex exec", timeoutSeconds: 10)
        XCTAssertEqual(LocalCLIExecutor.testConnectionConfig(for: fast).timeoutSeconds, 10)
        XCTAssertEqual(LocalCLIExecutor.testConnectionConfig(for: fast).commandTemplate, "codex exec")
    }

    // MARK: - Templates

    func testTemplateDefaults() {
        XCTAssertEqual(LocalCLITemplate.claudeCode.defaultCommand, "claude -p --model haiku")
        XCTAssertEqual(
            LocalCLITemplate.codex.defaultCommand,
            "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        )
        XCTAssertEqual(LocalCLITemplate.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(LocalCLITemplate.codex.displayName, "Codex")
    }

    func testTemplateInferenceAndDisplayNames() {
        XCTAssertEqual(
            LocalCLITemplate.inferredTemplate(for: "claude -p --model sonnet"),
            .claudeCode
        )
        XCTAssertEqual(
            LocalCLITemplate.inferredTemplate(for: "codex exec --model gpt-5.4"),
            .codex
        )
        XCTAssertNil(LocalCLITemplate.inferredTemplate(for: "my-wrapper --run codex"))
        XCTAssertEqual(LocalCLITemplate.displayName(for: "codex exec --model gpt-5.4"), "Codex")
        XCTAssertEqual(LocalCLITemplate.displayName(for: "python llm_wrapper.py"), "Custom CLI")
    }

    // MARK: - Prompt Formatting

    func testFormatFullPromptWithSystem() {
        let result = LocalCLIExecutor.formatFullPrompt(system: "Be helpful.", user: "Hello")
        XCTAssertTrue(result.contains("Be helpful."))
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("---"))
    }

    func testFormatFullPromptWithoutSystem() {
        let result = LocalCLIExecutor.formatFullPrompt(system: "", user: "Hello")
        XCTAssertEqual(result, "Hello")
    }

    // MARK: - Executor

    func testSuccessfulExecution() async throws {
        let executor = LocalCLIExecutor()

        let config = LocalCLIConfig(commandTemplate: "printf 'test output'", timeoutSeconds: 10)
        let output = try await executor.execute(
            systemPrompt: "", userPrompt: "ignored", config: config
        )
        XCTAssertEqual(output, "test output")
    }

    func testExecutionUsesAppOwnedWorkingDirectory() async throws {
        let executor = LocalCLIExecutor()
        let output = try await executor.execute(
            systemPrompt: "",
            userPrompt: "",
            config: LocalCLIConfig(commandTemplate: "printf '%s' \"$PWD\"", timeoutSeconds: 10)
        )

        let workingDirectory = try LocalCLIExecutor.executionWorkingDirectory()
        XCTAssertEqual(output, workingDirectory.path)
    }

    func testSuccessfulExecutionPreservesStdoutWhitespace() async throws {
        let executor = LocalCLIExecutor()

        let config = LocalCLIConfig(
            commandTemplate: "printf '\\n  indented\\n'",
            timeoutSeconds: 10
        )
        let output = try await executor.execute(
            systemPrompt: "",
            userPrompt: "",
            config: config
        )

        XCTAssertEqual(output, "\n  indented\n")
    }

    func testStdinDelivery() async throws {
        let executor = LocalCLIExecutor()

        // `cat` echoes stdin to stdout
        let config = LocalCLIConfig(commandTemplate: "cat", timeoutSeconds: 10)
        let output = try await executor.execute(
            systemPrompt: "System", userPrompt: "User", config: config
        )
        // Output should contain the full prompt (system + user)
        XCTAssertTrue(output.contains("System"))
        XCTAssertTrue(output.contains("User"))
    }

    func testPromptContentIsNotExposedViaEnvironmentVariables() async throws {
        let executor = LocalCLIExecutor()
        let config = LocalCLIConfig(
            commandTemplate: """
            printf 'system=%s\\n' "${MACPARAKEET_SYSTEM_PROMPT-unset}"
            printf 'user=%s\\n' "${MACPARAKEET_USER_PROMPT-unset}"
            printf 'full=%s\\n' "${MACPARAKEET_FULL_PROMPT-unset}"
            printf 'stdin='
            cat
            """,
            timeoutSeconds: 10
        )

        let output = try await executor.execute(
            systemPrompt: "System secret",
            userPrompt: "User secret",
            config: config
        )

        XCTAssertTrue(output.contains("system=unset"))
        XCTAssertTrue(output.contains("user=unset"))
        XCTAssertTrue(output.contains("full=unset"))
        XCTAssertTrue(output.contains("stdin=System secret"))
        XCTAssertTrue(output.contains("User secret"))
    }

    func testNonZeroExit() async throws {
        let executor = LocalCLIExecutor()

        let config = LocalCLIConfig(commandTemplate: "exit 1", timeoutSeconds: 10)
        do {
            _ = try await executor.execute(systemPrompt: "", userPrompt: "", config: config)
            XCTFail("Expected nonZeroExit error")
        } catch let error as LocalCLIError {
            if case .nonZeroExit(let code, _) = error {
                XCTAssertEqual(code, 1)
            } else {
                XCTFail("Expected nonZeroExit, got \(error)")
            }
        }
    }

    func testTimeout() async throws {
        let executor = LocalCLIExecutor()

        // Minimum timeout is clamped to 5 seconds
        let config = LocalCLIConfig(commandTemplate: "sleep 30", timeoutSeconds: 5)
        do {
            _ = try await executor.execute(systemPrompt: "", userPrompt: "", config: config)
            XCTFail("Expected timeout error")
        } catch let error as LocalCLIError {
            if case .timeout(let seconds) = error {
                XCTAssertEqual(seconds, 5)
            } else {
                XCTFail("Expected timeout, got \(error)")
            }
        }
    }

    func testTimeoutWhileChildIsNotDrainingStdin() async throws {
        let executor = LocalCLIExecutor()
        let largePrompt = String(repeating: "x", count: 200_000)

        // `sleep` never reads stdin, so a large prompt would previously block
        // the synchronous write before timeout handling started.
        let config = LocalCLIConfig(commandTemplate: "sleep 30", timeoutSeconds: 5)
        do {
            _ = try await executor.execute(systemPrompt: "", userPrompt: largePrompt, config: config)
            XCTFail("Expected timeout error")
        } catch let error as LocalCLIError {
            guard case .timeout(let seconds) = error else {
                XCTFail("Expected timeout, got \(error)")
                return
            }
            XCTAssertEqual(seconds, 5)
        }
    }

    func testBackgroundChildIsCleanedUpWhenShellExits() async throws {
        let executor = LocalCLIExecutor()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localcli-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidPath = directory.appendingPathComponent("child.txt").path

        let config = LocalCLIConfig(
            commandTemplate: "sleep 30 & echo $! > \(shellQuote(pidPath)); printf ok",
            timeoutSeconds: 30
        )

        let output = try await executor.execute(systemPrompt: "", userPrompt: "", config: config)
        XCTAssertEqual(output, "ok")

        XCTAssertTrue(FileManager.default.fileExists(atPath: pidPath))
        let childPID = try XCTUnwrap(
            Int32(
                String(contentsOfFile: pidPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )

        let terminationDeadline = Date().addingTimeInterval(5)
        while isProcessRunning(childPID) && Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(isProcessRunning(childPID))
    }

    func testBackgroundGrandchildIsCleanedUpWhenShellExits() async throws {
        let executor = LocalCLIExecutor()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localcli-grandchild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let grandchildPIDPath = directory.appendingPathComponent("grandchild.txt").path

        let config = LocalCLIConfig(
            commandTemplate: """
            sh -c 'sleep 30 </dev/null >/dev/null 2>&1 & echo $! > \(shellQuote(grandchildPIDPath))' &
            while [ ! -f \(shellQuote(grandchildPIDPath)) ]; do sleep 0.01; done
            printf ok
            """,
            timeoutSeconds: 30
        )

        let output = try await executor.execute(systemPrompt: "", userPrompt: "", config: config)
        XCTAssertEqual(output, "ok")

        XCTAssertTrue(FileManager.default.fileExists(atPath: grandchildPIDPath))
        let grandchildPID = try XCTUnwrap(
            Int32(
                String(contentsOfFile: grandchildPIDPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )

        let terminationDeadline = Date().addingTimeInterval(5)
        while isProcessRunning(grandchildPID) && Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(isProcessRunning(grandchildPID))
    }

    func testCancellationTerminatesShellAndBackgroundChild() async throws {
        let executor = LocalCLIExecutor()

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localcli-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let startedPath = directory.appendingPathComponent("started.txt").path
        let shellPIDPath = directory.appendingPathComponent("shell.txt").path
        let childPIDPath = directory.appendingPathComponent("child.txt").path
        let command = """
        echo $$ > \(shellQuote(shellPIDPath))
        sleep 30 &
        echo $! > \(shellQuote(childPIDPath))
        echo started > \(shellQuote(startedPath))
        while true; do sleep 1; done
        """
        let config = LocalCLIConfig(commandTemplate: command, timeoutSeconds: 30)

        let task = Task {
            try await executor.execute(systemPrompt: "", userPrompt: "cancel me", config: config)
        }

        let didStart = try await waitForFiles(
            [startedPath, shellPIDPath, childPIDPath],
            timeout: 8
        )
        guard didStart else {
            task.cancel()
            guard await waitForTaskCompletionAfterCancel(task) else {
                XCTFail("Executor task did not finish promptly after cancellation")
                return
            }
            XCTFail(
                "Timed out waiting for cancellation fixtures: \(startedPath), \(shellPIDPath), \(childPIDPath)"
            )
            return
        }

        let shellPIDContents = try String(contentsOfFile: shellPIDPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shellPID = try XCTUnwrap(Int32(shellPIDContents))
        let childPIDContents = try String(contentsOfFile: childPIDPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDContents))

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let terminationDeadline = Date().addingTimeInterval(5)
        while (isProcessRunning(shellPID) || isProcessRunning(childPID)) && Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(isProcessRunning(shellPID))
        XCTAssertFalse(isProcessRunning(childPID))
    }

    func testEmptyOutput() async throws {
        let executor = LocalCLIExecutor()

        // `true` exits 0 but produces no output
        let config = LocalCLIConfig(commandTemplate: "true", timeoutSeconds: 10)
        do {
            _ = try await executor.execute(systemPrompt: "", userPrompt: "", config: config)
            XCTFail("Expected emptyOutput error")
        } catch let error as LocalCLIError {
            guard case .emptyOutput = error else {
                XCTFail("Expected emptyOutput, got \(error)")
                return
            }
        }
    }

    func testPromptEnvironmentVariablesAreNotSet() async throws {
        let executor = LocalCLIExecutor()

        // Print env vars to verify prompt content is not propagated via process env.
        let config = LocalCLIConfig(
            commandTemplate: """
            echo "sys:${MACPARAKEET_SYSTEM_PROMPT-unset} usr:${MACPARAKEET_USER_PROMPT-unset} full:${MACPARAKEET_FULL_PROMPT-unset}"
            """,
            timeoutSeconds: 10
        )
        let output = try await executor.execute(
            systemPrompt: "SysPrompt", userPrompt: "UsrPrompt", config: config
        )
        XCTAssertTrue(output.contains("sys:unset"))
        XCTAssertTrue(output.contains("usr:unset"))
        XCTAssertTrue(output.contains("full:unset"))
    }

    func testDiscoverPATHDrainsChattyStdoutBeforeWaitingForExit() {
        let path = LocalCLIExecutor.discoverPATH(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-e",
                """
                print "x" x 70000;
                print "__MACPARAKEET_PATH_START__\\n";
                print "/tmp/discovered/path\\n";
                print "__MACPARAKEET_PATH_END__\\n";
                """,
            ],
            timeout: 1
        )

        XCTAssertEqual(path, "/tmp/discovered/path")
    }

    func testCandidatePATHProbeShellURLsIgnoreExecutableEnvironmentShell() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localcli-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plantedShell = directory.appendingPathComponent("planted-shell")
        try createExecutable(at: plantedShell)

        let previousShell = getenv("SHELL").map { String(cString: $0) }
        setenv("SHELL", plantedShell.path, 1)
        defer {
            if let previousShell {
                setenv("SHELL", previousShell, 1)
            } else {
                unsetenv("SHELL")
            }
        }

        let paths = LocalCLIExecutor.candidatePATHProbeShellURLs(
            fileManager: .default
        ).map(\.path)

        XCTAssertNotEqual(paths.first, plantedShell.path)
        XCTAssertFalse(paths.contains(plantedShell.path))
    }

    func testCandidatePATHProbeShellURLsUseLoginShellAndStandardShellsInOrder() {
        let loginShell = LocalCLIExecutor.userLoginShellURL()?.path
        let environmentShell = "/tmp/attacker-shell"
        let executablePaths = Set(
            [loginShell].compactMap { $0 }
                + Self.standardPATHProbeShellPaths
                + [environmentShell]
        )
        let fileManager = ExecutablePathFileManager(executablePaths: executablePaths)

        let paths = LocalCLIExecutor.candidatePATHProbeShellURLs(
            fileManager: fileManager
        ).map(\.path)

        var seen = Set<String>()
        let expected = ([loginShell].compactMap { $0 } + Self.standardPATHProbeShellPaths)
            .filter { seen.insert($0).inserted }

        XCTAssertEqual(paths, expected)
        XCTAssertFalse(paths.contains(environmentShell))
        XCTAssertTrue(paths.contains("/bin/zsh"))
        XCTAssertTrue(paths.contains("/bin/bash"))
        XCTAssertTrue(paths.contains("/bin/sh"))
    }

    func testCandidatePATHProbeShellURLsFilterNonExecutableCandidateShells() {
        let executablePaths: Set<String> = ["/bin/zsh", "/bin/sh"]
        let fileManager = ExecutablePathFileManager(executablePaths: executablePaths)

        let paths = LocalCLIExecutor.candidatePATHProbeShellURLs(fileManager: fileManager).map(\.path)

        var seen = Set<String>()
        let expected = ([LocalCLIExecutor.userLoginShellURL()?.path].compactMap { $0 }
            + Self.standardPATHProbeShellPaths)
            .filter { path in
                executablePaths.contains(path) && seen.insert(path).inserted
            }

        XCTAssertEqual(paths, expected)
        XCTAssertTrue(paths.contains("/bin/zsh"))
        XCTAssertFalse(paths.contains("/bin/bash"))
        XCTAssertTrue(paths.contains("/bin/sh"))
    }

    func testCandidatePATHProbeShellURLsDeduplicatesCandidates() {
        let loginShell = LocalCLIExecutor.userLoginShellURL()?.path
        let executablePaths = Set([loginShell].compactMap { $0 } + Self.standardPATHProbeShellPaths)
        let fileManager = ExecutablePathFileManager(executablePaths: executablePaths)

        let paths = LocalCLIExecutor.candidatePATHProbeShellURLs(
            fileManager: fileManager
        ).map(\.path)

        XCTAssertEqual(paths.count, Set(paths).count)
        if let loginShell, Self.standardPATHProbeShellPaths.contains(loginShell) {
            XCTAssertEqual(paths.filter { $0 == loginShell }.count, 1)
        }
    }

    func testPathProbeArgumentsPreferInteractiveLoginForZshAndBash() {
        let script = "echo path"

        XCTAssertEqual(
            LocalCLIExecutor.pathProbeArguments(forShellPath: "/bin/zsh", script: script),
            [
                ["-i", "-l", "-c", script],
                ["-l", "-c", script],
            ]
        )
        XCTAssertEqual(
            LocalCLIExecutor.pathProbeArguments(forShellPath: "/bin/bash", script: script),
            [
                ["-i", "-l", "-c", script],
                ["-l", "-c", script],
            ]
        )
    }

    func testPathProbeArgumentsCoverFishAndFallbackShells() {
        let script = "echo path"

        XCTAssertEqual(
            LocalCLIExecutor.pathProbeArguments(forShellPath: "/opt/homebrew/bin/fish", script: script),
            [
                ["-i", "-l", "-c", script],
                ["-l", "-c", script],
                ["-c", script],
            ]
        )
        XCTAssertEqual(
            LocalCLIExecutor.pathProbeArguments(forShellPath: "/bin/sh", script: script),
            [["-c", script]]
        )
    }

    func testParsePathHelperPATH() {
        let output = """
        PATH="/usr/local/bin:/usr/bin:/bin"; export PATH;
        MANPATH="/usr/share/man"; export MANPATH;
        """

        XCTAssertEqual(
            LocalCLIExecutor.parsePathHelperPATH(in: output),
            "/usr/local/bin:/usr/bin:/bin"
        )
    }

    func testMergedPATHPreservesOrderAndDeduplicates() {
        XCTAssertEqual(
            LocalCLIExecutor.mergedPATH([
                "/usr/local/bin:/usr/bin",
                "/usr/bin:/bin",
                nil,
                "/opt/homebrew/bin:/bin",
            ]),
            "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        )
    }
}

private final class ExecutablePathFileManager: FileManager {
    private let executablePaths: Set<String>

    init(executablePaths: Set<String>) {
        self.executablePaths = executablePaths
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

import XCTest
@testable import MacParakeetCore

final class LocalCLIExecutorTests: XCTestCase {
    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func isProcessRunning(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
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

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: startedPath) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shellPIDPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPIDPath))

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

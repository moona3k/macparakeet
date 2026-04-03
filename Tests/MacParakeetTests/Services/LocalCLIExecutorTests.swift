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
        XCTAssertEqual(LocalCLITemplate.codex.defaultCommand, "codex exec --model gpt-5.4-mini")
        XCTAssertEqual(LocalCLITemplate.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(LocalCLITemplate.codex.displayName, "Codex")
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

        let config = LocalCLIConfig(commandTemplate: "echo 'test output'", timeoutSeconds: 10)
        let output = try await executor.execute(
            systemPrompt: "", userPrompt: "ignored", config: config
        )
        XCTAssertEqual(output, "test output")
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

    func testBackgroundChildHoldingPipesTriggersDrainTimeout() async throws {
        let executor = LocalCLIExecutor()

        let config = LocalCLIConfig(
            commandTemplate: "sleep 30 & echo ok",
            timeoutSeconds: 30
        )

        do {
            _ = try await executor.execute(systemPrompt: "", userPrompt: "", config: config)
            XCTFail("Expected drain timeout error")
        } catch let error as LocalCLIError {
            guard case .drainTimeout = error else {
                XCTFail("Expected drainTimeout, got \(error)")
                return
            }
        }
    }

    func testCancellationTerminatesChildProcess() async throws {
        let executor = LocalCLIExecutor()

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localcli-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let startedPath = directory.appendingPathComponent("started.txt").path
        let pidPath = directory.appendingPathComponent("pid.txt").path
        let command = """
        trap 'exit 0' TERM
        echo $$ > \(shellQuote(pidPath))
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidPath))

        let pidContents = try String(contentsOfFile: pidPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidContents))

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
        while isProcessRunning(pid) && Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(isProcessRunning(pid))
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

    func testEnvironmentVariablesSet() async throws {
        let executor = LocalCLIExecutor()

        // Print env vars to verify they're set
        let config = LocalCLIConfig(
            commandTemplate: "echo \"sys:$MACPARAKEET_SYSTEM_PROMPT usr:$MACPARAKEET_USER_PROMPT\"",
            timeoutSeconds: 10
        )
        let output = try await executor.execute(
            systemPrompt: "SysPrompt", userPrompt: "UsrPrompt", config: config
        )
        XCTAssertTrue(output.contains("sys:SysPrompt"))
        XCTAssertTrue(output.contains("usr:UsrPrompt"))
    }
}

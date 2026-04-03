import XCTest
@testable import MacParakeetCore

final class LocalCLIExecutorTests: XCTestCase {

    // MARK: - Config Store

    func testConfigStoreRoundTrip() throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)

        XCTAssertNil(store.load())

        let config = LocalCLIConfig(commandTemplate: "claude -p", timeoutSeconds: 90)
        try store.save(config)

        let loaded = store.load()
        XCTAssertEqual(loaded, config)

        store.delete()
        XCTAssertNil(store.load())
    }

    // MARK: - Templates

    func testTemplateDefaults() {
        XCTAssertEqual(LocalCLITemplate.claudeCode.defaultCommand, "claude -p")
        XCTAssertEqual(LocalCLITemplate.codex.defaultCommand, "codex exec")
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
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)
        let executor = LocalCLIExecutor(configStore: store)

        let config = LocalCLIConfig(commandTemplate: "echo 'test output'", timeoutSeconds: 10)
        let output = try await executor.execute(
            systemPrompt: "", userPrompt: "ignored", config: config
        )
        XCTAssertEqual(output, "test output")
    }

    func testStdinDelivery() async throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)
        let executor = LocalCLIExecutor(configStore: store)

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
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)
        let executor = LocalCLIExecutor(configStore: store)

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
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)
        let executor = LocalCLIExecutor(configStore: store)

        let config = LocalCLIConfig(commandTemplate: "sleep 30", timeoutSeconds: 1)
        do {
            _ = try await executor.execute(systemPrompt: "", userPrompt: "", config: config)
            XCTFail("Expected timeout error")
        } catch let error as LocalCLIError {
            if case .timeout(let seconds) = error {
                XCTAssertEqual(seconds, 1)
            } else {
                XCTFail("Expected timeout, got \(error)")
            }
        }
    }

    func testEmptyOutput() async throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)
        let executor = LocalCLIExecutor(configStore: store)

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

    func testCommandNotConfigured() async throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)
        let executor = LocalCLIExecutor(configStore: store)

        // No config saved, no override
        do {
            _ = try await executor.execute(systemPrompt: "", userPrompt: "")
            XCTFail("Expected commandNotConfigured error")
        } catch let error as LocalCLIError {
            guard case .commandNotConfigured = error else {
                XCTFail("Expected commandNotConfigured, got \(error)")
                return
            }
        }
    }

    func testEnvironmentVariablesSet() async throws {
        let defaults = UserDefaults(suiteName: "test.localcli.\(UUID().uuidString)")!
        let store = LocalCLIConfigStore(defaults: defaults)
        let executor = LocalCLIExecutor(configStore: store)

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

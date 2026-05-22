import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class LLMConfigCommandTests: XCTestCase {
    func testValidateCustomBaseURLAcceptsAbsoluteHTTPURL() throws {
        let url = try validateBaseURL("http://localhost:8000/v1")
        XCTAssertEqual(url.absoluteString, "http://localhost:8000/v1")
    }

    func testValidateCustomBaseURLAcceptsAbsoluteHTTPSURL() throws {
        let url = try validateBaseURL("https://example.com/openai")
        XCTAssertEqual(url.absoluteString, "https://example.com/openai")
    }

    func testValidateCustomBaseURLRejectsMissingScheme() {
        XCTAssertThrowsError(try validateBaseURL("localhost:8000/v1")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testValidateCustomBaseURLRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try validateBaseURL("ftp://example.com/v1")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testValidateCustomBaseURLRejectsMissingHost() {
        XCTAssertThrowsError(try validateBaseURL("https:///v1")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testInlineOptionsApplyBaseURLOverrideToOllama() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "ollama",
            "--base-url", "http://127.0.0.1:11435/v1",
            "--model", "llama3.2"
        ])

        let config = try options.buildConfig()
        XCTAssertEqual(config.id, .ollama)
        XCTAssertEqual(config.baseURL.absoluteString, "http://127.0.0.1:11435/v1")
    }

    func testInlineOptionsAllowOllamaHTTPOnLAN() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "ollama",
            "--base-url", "http://192.168.1.5:11434/v1",
            "--model", "llama3.2"
        ])

        let config = try options.buildConfig()
        XCTAssertEqual(config.id, .ollama)
        XCTAssertEqual(config.baseURL.absoluteString, "http://192.168.1.5:11434/v1")
        XCTAssertTrue(config.isLocal)
    }

    func testInlineOptionsBuildOpenAICompatibleConfig() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai-compatible",
            "--api-key", "sk-third-party",
            "--base-url", "https://api.example.com/v1",
            "--model", "vendor/model"
        ])

        let config = try options.buildConfig()
        XCTAssertEqual(config.id, .openaiCompatible)
        XCTAssertEqual(config.apiKey, "sk-third-party")
        XCTAssertEqual(config.baseURL.absoluteString, "https://api.example.com/v1")
        XCTAssertEqual(config.modelName, "vendor/model")
    }

    func testInlineOptionsBuildOpenAICompatibleConfigWithoutAPIKey() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai-compatible",
            "--base-url", "https://api.example.com/v1",
            "--model", "vendor/model"
        ])

        let config = try options.buildConfig()
        XCTAssertEqual(config.id, .openaiCompatible)
        XCTAssertNil(config.apiKey)
    }

    func testInlineOptionsBuildLMStudioConfigWithOptionalAPIKeyEnvironment() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "lmstudio",
            "--model", "local-model",
        ])

        let config = try options.buildConfig(environment: ["LM_API_TOKEN": "lm-token"])
        XCTAssertEqual(config.id, .lmstudio)
        XCTAssertEqual(config.apiKey, "lm-token")
        XCTAssertEqual(config.baseURL.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(config.modelName, "local-model")
        XCTAssertTrue(config.isLocal)
    }

    func testInlineOptionsBuildLMStudioConfigWithoutAPIKey() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "lmstudio",
            "--model", "local-model",
        ])

        let config = try options.buildConfig(environment: [:])
        XCTAssertEqual(config.id, .lmstudio)
        XCTAssertNil(config.apiKey)
        XCTAssertEqual(config.baseURL.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(config.modelName, "local-model")
        XCTAssertTrue(config.isLocal)
    }

    func testInlineOptionsReadStandardProviderEnvironment() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "anthropic",
            "--model", "claude-sonnet-4-6",
        ])

        let config = try options.buildConfig(environment: ["ANTHROPIC_API_KEY": "sk-env"])
        XCTAssertEqual(config.id, .anthropic)
        XCTAssertEqual(config.apiKey, "sk-env")
    }

    func testInlineOptionsReadExplicitAPIKeyEnvironment() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai-compatible",
            "--api-key-env", "VENDOR_API_KEY",
            "--base-url", "https://api.example.com/v1",
            "--model", "vendor/model",
        ])

        let config = try options.buildConfig(environment: ["VENDOR_API_KEY": "sk-vendor"])
        XCTAssertEqual(config.id, .openaiCompatible)
        XCTAssertEqual(config.apiKey, "sk-vendor")
    }

    func testInlineOptionsRejectMissingExplicitAPIKeyEnvironment() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai",
            "--api-key-env", "MISSING_API_KEY",
            "--model", "gpt-4.1",
        ])

        XCTAssertThrowsError(try options.buildConfig(environment: [:])) { error in
            XCTAssertTrue(error is ValidationError)
            XCTAssertTrue(String(describing: error).contains("MISSING_API_KEY"))
        }
    }

    func testInlineOptionsRejectWhitespaceOnlyAPIKey() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai",
            "--api-key", "   \n  ",
            "--model", "gpt-4.1",
        ])

        XCTAssertThrowsError(try options.buildConfig(environment: ["OPENAI_API_KEY": "sk-env"])) { error in
            XCTAssertTrue(error is ValidationError)
            XCTAssertTrue(String(describing: error).contains("--api-key must not be empty"))
        }
    }

    func testInlineOptionsBuildOpenAICompatibleLocalConfig() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai-compatible",
            "--base-url", "http://localhost:8000/v1",
            "--model", "local-model"
        ])

        let config = try options.buildConfig()
        XCTAssertEqual(config.id, .openaiCompatible)
        XCTAssertTrue(config.isLocal)
    }

    func testInlineOptionsRejectOpenAICompatibleHTTPOnLANWithoutExplicitAllow() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai-compatible",
            "--base-url", "http://192.168.1.5:8000/v1",
            "--model", "local-model"
        ])

        XCTAssertThrowsError(try options.buildConfig(emitWarnings: false)) { error in
            XCTAssertTrue(error is ValidationError)
            XCTAssertTrue(String(describing: error).contains("--allow-insecure-http"))
        }
    }

    func testInlineOptionsAllowOpenAICompatibleHTTPOnLANWithExplicitFlag() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai-compatible",
            "--base-url", "http://192.168.1.5:8000/v1",
            "--allow-insecure-http",
            "--model", "local-model"
        ])

        let config = try options.buildConfig(emitWarnings: false)
        XCTAssertEqual(config.id, .openaiCompatible)
        XCTAssertEqual(config.baseURL.absoluteString, "http://192.168.1.5:8000/v1")
        XCTAssertFalse(config.isLocal)
    }

    func testInlineOptionsRejectHostedProviderHTTPOnLANWithoutExplicitAllow() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai",
            "--api-key-env", "OPENAI_API_KEY",
            "--base-url", "http://api.example.com/v1",
            "--model", "gpt-4.1"
        ])

        XCTAssertThrowsError(
            try options.buildConfig(
                environment: ["OPENAI_API_KEY": "sk-env"],
                emitWarnings: false
            )
        ) { error in
            XCTAssertTrue(error is ValidationError)
            XCTAssertTrue(String(describing: error).contains("--allow-insecure-http"))
        }
    }

    func testInlineOptionsAllowHostedProviderHTTPOnLANWithExplicitFlag() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai",
            "--api-key-env", "OPENAI_API_KEY",
            "--base-url", "http://api.example.com/v1",
            "--allow-insecure-http",
            "--model", "gpt-4.1"
        ])

        let config = try options.buildConfig(
            environment: ["OPENAI_API_KEY": "sk-env"],
            emitWarnings: false
        )
        XCTAssertEqual(config.id, .openai)
        XCTAssertEqual(config.baseURL.absoluteString, "http://api.example.com/v1")
        XCTAssertEqual(config.apiKey, "sk-env")
    }

    func testInsecureHTTPWarningNamesProviderAndURL() throws {
        let warning = LLMInlineOptions.insecureHTTPWarning(
            url: URL(string: "http://api.example.com/v1")!,
            providerID: .openai
        )

        XCTAssertTrue(warning.contains("--allow-insecure-http"))
        XCTAssertTrue(warning.contains("OpenAI"))
        XCTAssertTrue(warning.contains("http://api.example.com/v1"))
        XCTAssertTrue(warning.contains("without TLS"))
    }

    func testInlineOptionsLocalFlagMarksRemoteProviderAsLocal() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "openai-compatible",
            "--base-url", "https://lan-proxy.example/v1",
            "--model", "self-hosted-model",
            "--local"
        ])

        let config = try options.buildConfig()
        XCTAssertEqual(config.id, .openaiCompatible)
        XCTAssertTrue(config.isLocal)
    }

    func testLocalCLIExecutionContextRoutesThroughCLIClient() async throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "cli",
            "--command", "echo OK",
        ])

        let context = try options.buildExecutionContext()

        XCTAssertEqual(context.context.providerConfig.id, .localCLI)
        XCTAssertEqual(context.context.localCLIConfig?.commandTemplate, "echo OK")
        try await context.client.testConnection(context: context.context)
    }

    func testLocalCLIRejectsWhitespaceOnlyCommand() throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "cli",
            "--command", "   \n  ",
        ])

        XCTAssertThrowsError(try options.buildExecutionContext()) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

}

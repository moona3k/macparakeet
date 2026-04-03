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

    func testLocalCLIExecutionContextRoutesThroughCLIClient() async throws {
        let options = try LLMInlineOptions.parse([
            "--provider", "localCLI",
            "--command", "echo OK",
        ])

        let context = try options.buildExecutionContext()

        XCTAssertEqual(context.context.providerConfig.id, .localCLI)
        XCTAssertEqual(context.context.localCLIConfig?.commandTemplate, "echo OK")
        try await context.client.testConnection(context: context.context)
    }

}

import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

/// Schema and validation tests for the CLI's `--json` output mode.
/// `LLMResultTests` covers the `MacParakeetCore` envelope; this file
/// covers CLI-only concerns: the test-connection success shape and the
/// `--json` × `--stream` rejection contract.
final class LLMJSONOutputTests: XCTestCase {

    // MARK: - LLMTestConnectionResult schema lock

    func testLLMTestConnectionResultEncodesExpectedShape() throws {
        let result = LLMTestConnectionResult(
            ok: true,
            provider: "anthropic",
            model: "claude-sonnet-4-6",
            latencyMs: 234
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(
            json,
            #"{"latencyMs":234,"model":"claude-sonnet-4-6","ok":true,"provider":"anthropic"}"#
        )
    }

    // MARK: - --json × --stream rejection
    //
    // ArgumentParser's `parse(_:)` runs `validate()` as part of parsing,
    // so a validation error surfaces during `parse` rather than as a
    // separate step. Each rejection test asserts that `parse` throws
    // and that the human-readable text mentions both flag names so a
    // future refactor can't accidentally drop the actionable hint.

    func testSummarizeRejectsJSONWithStream() {
        assertParseRejects(
            command: LLMSummarizeCommand.self,
            args: [
                "--provider", "ollama",
                "--model", "qwen3.5:4b",
                "--json",
                "--stream",
                "-",
            ]
        )
    }

    func testChatRejectsJSONWithStream() {
        assertParseRejects(
            command: LLMChatCommand.self,
            args: [
                "--provider", "ollama",
                "--model", "qwen3.5:4b",
                "--question", "Why?",
                "--json",
                "--stream",
                "-",
            ]
        )
    }

    func testTransformRejectsJSONWithStream() {
        assertParseRejects(
            command: LLMTransformCommand.self,
            args: [
                "--provider", "ollama",
                "--model", "qwen3.5:4b",
                "--prompt", "Make it formal",
                "--json",
                "--stream",
                "-",
            ]
        )
    }

    func testPromptsRunRejectsJSONWithStream() {
        assertParseRejects(
            command: PromptsCommand.RunSubcommand.self,
            args: [
                "--provider", "ollama",
                "--model", "qwen3.5:4b",
                "--transcription", "abcd",
                "--json",
                "--stream",
                "Action items",
            ]
        )
    }

    func testSummarizeAcceptsJSONWithoutStream() throws {
        // The complement: --json on its own must parse cleanly.
        XCTAssertNoThrow(try LLMSummarizeCommand.parse([
            "--provider", "ollama",
            "--model", "qwen3.5:4b",
            "--json",
            "-",
        ]))
    }

    func testSummarizeAcceptsStreamWithoutJSON() throws {
        XCTAssertNoThrow(try LLMSummarizeCommand.parse([
            "--provider", "ollama",
            "--model", "qwen3.5:4b",
            "--stream",
            "-",
        ]))
    }

    // MARK: - --json failure envelope (AUDIT-007)

    func testCLIErrorEnvelopeEncodesShape() throws {
        let envelope = CLIErrorEnvelope(
            ok: false,
            error: "Authentication failed: invalid API key.",
            errorType: "auth"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(envelope)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"error":"Authentication failed: invalid API key.","errorType":"auth","ok":false}"#
        )
    }

    func testCLIErrorEnvelopeUsesLocalizedDescriptionFromLLMError() {
        let envelope = CLIErrorEnvelope(error: LLMError.rateLimited)
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.errorType, "rate_limit")
        XCTAssertTrue(envelope.error.lowercased().contains("rate"))
    }

    func testCLIErrorTypeMapsLLMErrorCases() {
        // Pin the public `errorType` taxonomy so renames in LLMError can't
        // silently break downstream agents that branch on these strings.
        XCTAssertEqual(CLIErrorType.key(for: LLMError.notConfigured), "config")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.connectionFailed("nope")), "connection")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.authenticationFailed(nil)), "auth")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.rateLimited), "rate_limit")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.modelNotFound("gpt-9")), "model")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.contextTooLong), "context")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.formatterTruncated), "truncated")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.formatterEmptyResponse), "truncated")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.providerError("oops")), "provider")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.streamingError("eof")), "streaming")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.invalidResponse), "invalid_response")
        XCTAssertEqual(CLIErrorType.key(for: LLMError.cliError("boom")), "runtime")
    }

    func testCLIErrorTypeMapsCLIErrors() {
        XCTAssertEqual(CLIErrorType.key(for: CLILookupError.emptyID), "lookup")
        XCTAssertEqual(CLIErrorType.key(for: CLILookupError.notFound("nope")), "lookup")
        XCTAssertEqual(CLIErrorType.key(for: CLIInputError.empty), "input_empty")
        XCTAssertEqual(CLIErrorType.key(for: ValidationError("bad combo")), "validation")

        struct UnknownError: Error {}
        XCTAssertEqual(CLIErrorType.key(for: UnknownError()), "runtime")
    }

    func testSyncJSONWrapperEmitsEnvelopeForPostParseFailure() throws {
        var thrownError: Error?
        let output = try captureStandardOutput {
            do {
                try emitJSONOrRethrow(json: true) {
                    throw CLILookupError.notFound("No transcription matching 'missing'")
                }
            } catch {
                thrownError = error
            }
        }

        let exit = try XCTUnwrap(thrownError as? ExitCode)
        XCTAssertEqual(exit, .failure)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["errorType"] as? String, "lookup")
        XCTAssertTrue((object["error"] as? String)?.contains("No transcription") == true)
    }

    func testJSONWrapperUsesDocumentedValidationMisuseExitCode() throws {
        var thrownError: Error?
        let output = try captureStandardOutput {
            do {
                try emitJSONOrRethrow(json: true) {
                    throw ValidationError("bad combo")
                }
            } catch {
                thrownError = error
            }
        }

        let exit = try XCTUnwrap(thrownError as? ExitCode)
        XCTAssertEqual(exit.rawValue, 2)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["errorType"] as? String, "validation")
    }

    func testCLINormalizesArgumentParserValidationExitCodeToPublicContract() {
        XCTAssertEqual(CLI.normalizedExitCode(for: ExitCode.validationFailure).rawValue, 2)
        XCTAssertEqual(CLI.normalizedExitCode(for: ValidationError("bad combo")).rawValue, 2)
        XCTAssertEqual(CLI.normalizedExitCode(for: ExitCode.failure), .failure)
    }

    // MARK: - Helpers

    private func assertParseRejects<C: ParsableCommand>(
        command: C.Type,
        args: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try C.parse(args)
            XCTFail("Expected --json with --stream to be rejected at parse time.", file: file, line: line)
        } catch {
            // The exit message contains the validation text — assert the
            // hint mentions both flags so the actionable message can't
            // silently degrade to a generic ArgumentParser error.
            let message = C.message(for: error)
            XCTAssertTrue(
                message.contains("--json") && message.contains("--stream"),
                "Expected message to mention both --json and --stream, got: \(message)",
                file: file,
                line: line
            )
        }
    }
}

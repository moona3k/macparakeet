import Foundation
import Testing
@testable import MacParakeetCore

/// Pins the `cli_operation` event's prop schema. The point of these tests is
/// not to catch a typo — `compactProps` already does that — but to make any
/// future addition of a path-shaped, URL-shaped, or content-shaped prop fail
/// loudly at PR review time. If you're adding `file_path`, `youtube_url`,
/// `transcript_excerpt`, etc., these tests are doing their job.
@Suite("cli_operation privacy schema")
struct CLIOperationPrivacyTests {

    @Test("cli_operation never emits forbidden keys, even with a YouTube input_kind")
    func cliOperationNeverShipsForbiddenKeys() {
        let context = ObservabilityOperationContext(
            operationID: "op-1",
            workflowID: "wf-1",
            parentOperationID: nil
        )
        let event = TelemetryEventSpec.cliOperation(
            operationID: "op-1",
            operationContext: context,
            command: "transcribe",
            subcommand: nil,
            outcome: .success,
            durationSeconds: 12.5,
            inputKind: .youtube,
            outputFormat: "json",
            json: true,
            exitCode: 0,
            errorType: nil
        )

        let props = event.props ?? [:]

        let forbidden: Set<String> = [
            "file_path", "path", "filename", "input_path",
            "url", "youtube_url", "video_url", "video_id",
            "transcript", "transcript_excerpt", "raw_transcript", "clean_transcript",
            "language", "host", "hostname",
            "device_name", "device_uid", "microphone", "microphone_name",
            "user_email", "email"
        ]
        for key in forbidden {
            #expect(props[key] == nil, "cli_operation must not include \(key); got \(props[key] ?? "<nil>")")
        }
    }

    @Test("cli_operation prop keys stay within the documented allowlist")
    func cliOperationAllowlistStable() {
        let event = TelemetryEventSpec.cliOperation(
            operationID: "op-1",
            operationContext: ObservabilityOperationContext(operationID: "op-1"),
            command: "transcribe",
            subcommand: "sub",
            outcome: .failure,
            durationSeconds: 1.2,
            inputKind: .audio,
            outputFormat: "text",
            json: false,
            exitCode: 1,
            errorType: "URLError.timedOut"
        )

        let allowed: Set<String> = [
            "operation_id", "workflow_id", "parent_operation_id",
            "command", "subcommand",
            "outcome", "duration_seconds",
            "input_kind", "output_format", "json",
            "exit_code", "error_type"
        ]

        let actual = Set((event.props ?? [:]).keys)
        let unexpected = actual.subtracting(allowed)
        #expect(unexpected.isEmpty, "cli_operation introduced new prop key(s) \(unexpected) — review for privacy and update docs/telemetry.md + integrations/README.md before merging.")

        let requiredForTranscribeFailure: Set<String> = [
            "operation_id", "workflow_id",
            "command",
            "outcome", "duration_seconds",
            "input_kind", "output_format", "json",
            "exit_code", "error_type"
        ]
        let missing = requiredForTranscribeFailure.subtracting(actual)
        #expect(missing.isEmpty, "cli_operation dropped required transcribe failure prop key(s) \(missing) — this is a schema regression.")
    }

    @Test("input_kind serializes to the enum case name; no path/URL substrings leak into any prop value")
    func inputKindIsEnumOnly() {
        // Defense in depth: if a future refactor of `compactProps` started
        // splatting the original input string into a prop value, the contains()
        // assertions below would catch it.
        let event = TelemetryEventSpec.cliOperation(
            operationID: "op-1",
            operationContext: nil,
            command: "transcribe",
            subcommand: nil,
            outcome: .success,
            durationSeconds: 1.0,
            inputKind: .audio,
            outputFormat: nil,
            json: nil,
            exitCode: nil,
            errorType: nil
        )
        let props = event.props ?? [:]
        #expect(props["input_kind"] == "audio")
        // Also make sure no other prop accidentally captured a path-shaped string.
        for (_, value) in props {
            #expect(!value.contains("/Users/"), "Found `/Users/` in cli_operation prop value: \(value)")
            #expect(!value.contains("file://"), "Found `file://` in cli_operation prop value: \(value)")
            #expect(!value.lowercased().contains("youtube.com"), "Found `youtube.com` in cli_operation prop value: \(value)")
        }
    }
}

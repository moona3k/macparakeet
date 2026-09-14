import ArgumentParser
import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

@MainActor
final class MeetingImportCommandTests: XCTestCase {
    private var sourceURL: URL!

    override func setUpWithError() throws {
        sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-import-\(UUID().uuidString).m4a")
        try Data().write(to: sourceURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceURL)
    }

    func testParsesOneSourceAndRejectsWhitespaceTitleOrConflictingJSONFlags() throws {
        let command = try MeetingsCommand.ImportSubcommand.parse([
            sourceURL.path, "--title", "Planning", "--started-at", "2026-05-14", "--json",
        ])
        XCTAssertEqual(command.path, sourceURL.path)
        XCTAssertEqual(command.title, "Planning")
        XCTAssertEqual(command.startedAt, "2026-05-14")
        XCTAssertTrue(command.json)

        XCTAssertThrowsError(
            try MeetingsCommand.ImportSubcommand.parse([
                sourceURL.path, "--title", "  ",
            ]))
        XCTAssertThrowsError(
            try MeetingsCommand.ImportSubcommand.parse([
                sourceURL.path, "--json", "--envelope",
            ]))
    }

    func testParsesDateOnlyAtLocalMidnightAndISO8601InstantStrictly() throws {
        let local = try XCTUnwrap(MeetingsCommand.ImportSubcommand.parseStartedAt("2026-05-14"))
        XCTAssertEqual(Calendar.current.component(.hour, from: local), 0)
        XCTAssertEqual(Calendar.current.component(.minute, from: local), 0)

        let instant = try XCTUnwrap(MeetingsCommand.ImportSubcommand.parseStartedAt("2026-05-14T17:30:00Z"))
        XCTAssertEqual(ISO8601DateFormatter().string(from: instant), "2026-05-14T17:30:00Z")
        XCTAssertThrowsError(try MeetingsCommand.ImportSubcommand.parseStartedAt("2026-5-14"))
        XCTAssertThrowsError(try MeetingsCommand.ImportSubcommand.parseStartedAt("2026-05-14 noon"))
    }

    func testPartialJSONUsesStableCamelCaseRecordAndSafeWarning() async throws {
        let transcription = meeting(status: .completed)
        let importRunner: MeetingImportRunning = { _, progress in
            progress(.preparingMedia)
            progress(.published(transcription))
            return MeetingImportResult(
                transcription: transcription,
                warnings: [
                    .artifactRefreshFailed(message: "/private/raw"),
                    .knowledgeCardFailed(message: "/private/card"),
                ]
            )
        }
        let command = try MeetingsCommand.ImportSubcommand.parse([sourceURL.path, "--json"])
        let output = try await captureStandardOutput { try await command.run(importRunner: importRunner) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])

        XCTAssertEqual(object["id"] as? String, transcription.id.uuidString)
        XCTAssertEqual(object["completion"] as? String, "partial")
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["title"] as? String, transcription.effectiveDisplayTitle)
        XCTAssertEqual(object["durationMs"] as? Int, 90_000)
        let warnings = try XCTUnwrap(object["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.first?["kind"] as? String, "artifactRefreshFailed")
        XCTAssertEqual(
            warnings.first?["message"] as? String, "Some meeting details could not finish. The transcript is ready.")
        XCTAssertEqual(warnings.last?["kind"] as? String, "knowledgeCardFailed")
        XCTAssertEqual(
            warnings.last?["message"] as? String, "The knowledge card could not finish. The transcript is ready.")
        XCTAssertFalse(output.contains("/private/raw"))
        XCTAssertFalse(output.contains("/private/card"))
    }

    func testNeedsRetryPrintsDurableResultBeforeFailureExit() async throws {
        let transcription = meeting(status: .error)
        let importRunner: MeetingImportRunning = { _, _ in
            MeetingImportResult(
                transcription: transcription, warnings: [.transcriptionFailed(message: "provider detail")])
        }
        let command = try MeetingsCommand.ImportSubcommand.parse([sourceURL.path, "--json"])
        var caught: Error?
        let output = try await captureStandardOutput {
            do {
                try await command.run(importRunner: importRunner)
            } catch {
                caught = error
            }
        }

        XCTAssertEqual(caught as? ExitCode, .failure)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["completion"] as? String, "needsRetry")
        XCTAssertEqual(object["status"] as? String, "error")
        XCTAssertFalse(output.contains("provider detail"))
    }

    func testInterruptedDurableResultPrintsBeforeExit130() async throws {
        let transcription = meeting(status: .cancelled)
        let importRunner: MeetingImportRunning = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return MeetingImportResult(
                transcription: transcription,
                warnings: [.transcriptionCancelled]
            )
        }
        let command = try MeetingsCommand.ImportSubcommand.parse([sourceURL.path, "--json"])
        var caught: Error?
        let output = try await captureStandardOutput {
            do {
                try await command.run(importRunner: importRunner)
            } catch {
                caught = error
            }
        }

        XCTAssertEqual(caught as? ExitCode, ExitCode(130))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, transcription.id.uuidString)
        XCTAssertEqual(object["completion"] as? String, "needsRetry")
        XCTAssertEqual(object["status"] as? String, "cancelled")
    }

    func testEnvelopeWrapsTheSameStableImportRecord() async throws {
        let transcription = meeting(status: .completed)
        let capturedRequest = CapturedImportRequest()
        let importRunner: MeetingImportRunning = { request, _ in
            capturedRequest.set(request)
            return MeetingImportResult(transcription: transcription)
        }
        let command = try MeetingsCommand.ImportSubcommand.parse([
            sourceURL.path, "--title", "Imported planning", "--started-at", "2026-05-14T17:30:00Z", "--envelope",
        ])
        let output = try await captureStandardOutput { try await command.run(importRunner: importRunner) }
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])

        XCTAssertEqual(envelope["ok"] as? Bool, true)
        XCTAssertEqual(envelope["command"] as? String, "meetings import")
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["id"] as? String, transcription.id.uuidString)
        XCTAssertEqual(data["completion"] as? String, "completed")
        let request = try XCTUnwrap(capturedRequest.value)
        XCTAssertEqual(request.sourceURL, sourceURL)
        XCTAssertEqual(request.titleOverride, "Imported planning")
        XCTAssertEqual(ISO8601DateFormatter().string(from: try XCTUnwrap(request.startedAt)), "2026-05-14T17:30:00Z")
    }

    func testImportErrorValidationTaxonomy() {
        for error in [
            MeetingImportError.invalidSource,
            .unsupportedFormat,
            .blankTitle,
        ] {
            XCTAssertTrue(isCLIValidationMisuse(error))
            XCTAssertEqual(CLIErrorType.key(for: error), CLIErrorType.validation)
        }
        XCTAssertFalse(isCLIValidationMisuse(MeetingImportError.invalidAudio))
        XCTAssertEqual(CLIErrorType.key(for: MeetingImportError.invalidAudio), CLIErrorType.runtime)
    }

    func testRecordOmitsManagedAudioPathAfterRetentionRemovesAudio() {
        var transcription = meeting(status: .completed)
        transcription.filePath = nil
        transcription.meetingArtifactFolderPath = "/managed/meeting"

        XCTAssertNil(MeetingImportRecord(.init(transcription: transcription)).managedAudioPath)
    }

    func testHumanResultExplainsWhenRetentionRemovedManagedAudio() async throws {
        var retainedTranscription = meeting(status: .completed)
        retainedTranscription.filePath = nil
        let transcription = retainedTranscription
        let importRunner: MeetingImportRunning = { _, _ in MeetingImportResult(transcription: transcription) }
        let command = try MeetingsCommand.ImportSubcommand.parse([sourceURL.path])

        let output = try await captureStandardOutput { try await command.run(importRunner: importRunner) }

        XCTAssertTrue(output.contains("Transcript and search are ready."))
        XCTAssertTrue(output.contains("Managed audio was removed by your retention setting."))
        XCTAssertTrue(output.contains("Your source recording was unchanged."))
        XCTAssertFalse(output.contains("playback are ready"))
    }

    private func meeting(status: Transcription.TranscriptionStatus) -> Transcription {
        Transcription(
            fileName: "Partnership discussion",
            durationMs: 90_000,
            status: status,
            sourceType: .meeting
        )
    }
}

private final class CapturedImportRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: MeetingImportRequest?

    var value: MeetingImportRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ request: MeetingImportRequest) {
        lock.lock()
        storedValue = request
        lock.unlock()
    }
}

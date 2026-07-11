import XCTest
@testable import CLI
@testable import MacParakeetCore

final class SearchCommandTests: XCTestCase {
    func testSearchAndTranscriptCommandsAreRegisteredAtTopLevel() {
        XCTAssertTrue(CLI.configuration.subcommands.contains { $0 == SearchCommand.self })
        XCTAssertTrue(CLI.configuration.subcommands.contains { $0 == SearchReindexCommand.self })
        XCTAssertTrue(CLI.configuration.subcommands.contains { $0 == TranscriptCommand.self })
    }

    func testSearchJSONShapeAndEnvelope() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let command = try SearchCommand.parse([
            "cache", "--source", "meeting", "--speaker", "Dana", "--json",
            "--database", fixture.path,
        ])
        let output = try await captureStandardOutput { try await command.run() }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        let hit = try XCTUnwrap(payload.first)
        XCTAssertEqual(
            Set(hit.keys),
            ["transcriptionId", "title", "recordedAt", "source", "seq", "startMs", "speaker", "snippet", "rank"]
        )
        XCTAssertEqual(hit["transcriptionId"] as? String, fixture.meetingID.uuidString)
        XCTAssertEqual(hit["source"] as? String, "meeting")
        XCTAssertEqual(hit["speaker"] as? String, "Dana")
        XCTAssertNotNil(hit["rank"] as? Double)

        let envelopeCommand = try SearchCommand.parse([
            "cache", "--envelope", "--database", fixture.path,
        ])
        let envelopeOutput = try await captureStandardOutput { try await envelopeCommand.run() }
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelopeOutput.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        XCTAssertEqual(envelope["command"] as? String, "search")
        XCTAssertNotNil(envelope["data"] as? [[String: Any]])
    }

    func testSearchReindexConvergesAndEmitsCounts() async throws {
        let fixture = try makeFixture(index: false)
        defer { fixture.cleanup() }

        let command = try SearchReindexCommand.parse([
            "--json", "--database", fixture.path,
        ])
        let firstOutput = try await captureStandardOutput { try await command.run() }
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstOutput.utf8)) as? [String: Any])
        let secondOutput = try await captureStandardOutput { try await command.run() }
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(secondOutput.utf8)) as? [String: Any])
        XCTAssertEqual(first["transcriptionsIndexed"] as? Int, 2)
        XCTAssertEqual(first["segmentsIndexed"] as? Int, 2)
        XCTAssertEqual(first as NSDictionary, second as NSDictionary)
    }

    func testRootParserRoutesSearchQueryAndMaintenanceVerbSeparately() throws {
        XCTAssertTrue(try CLI.parseAsRoot(["search", "reindex"]) is SearchCommand)
        XCTAssertTrue(try CLI.parseAsRoot(["search-reindex"]) is SearchReindexCommand)
    }

    func testTranscriptJSONWorksForFileIDWithTimeAndSequenceSlices() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let command = try TranscriptCommand.parse([
            fixture.fileID.uuidString,
            "--around-seq", "0",
            "--context", "1",
            "--json",
            "--database", fixture.path,
        ])
        let output = try await captureStandardOutput { try await command.run() }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(payload["transcriptionId"] as? String, fixture.fileID.uuidString)
        XCTAssertEqual(payload["source"] as? String, "file")
        let segments = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["seq"] as? Int, 0)
        XCTAssertEqual(segments.first?["startMs"] as? Int, 0)
        XCTAssertEqual(segments.first?["text"] as? String, "Local file cache notes.")

        XCTAssertNoThrow(
            try TranscriptCommand.parse([
                fixture.meetingID.uuidString, "--around", "00:00:03", "--window", "2s",
            ]))
    }

    func testSearchValidationUsesPublicMisuseExitCode() {
        XCTAssertThrowsError(try SearchCommand.parse(["query", "--limit", "-1"])) { error in
            XCTAssertEqual(CLI.normalizedExitCode(for: error).rawValue, 2)
        }
        XCTAssertThrowsError(try TranscriptCommand.parse(["id", "--around", "1", "--around-seq", "1"])) { error in
            XCTAssertEqual(CLI.normalizedExitCode(for: error).rawValue, 2)
        }
        XCTAssertThrowsError(try TranscriptCommand.parse(["id", "--window", String(repeating: "9", count: 100)])) {
            error in
            XCTAssertEqual(CLI.normalizedExitCode(for: error).rawValue, 2)
        }
    }

    func testCJKSearchJSONUsesNullRankAndSafeSnippet() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-search-cjk-\(UUID().uuidString).db").path
        defer { Fixture(path: path, meetingID: UUID(), fileID: UUID()).cleanup() }
        let manager = try DatabaseManager(path: path)
        let transcription = Transcription(
            fileName: "日本語",
            rawTranscript: "前置き🙂これは重要な会議の結論です🚀次の話題",
            status: .completed,
            sourceType: .file
        )
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        try SegmentRepository(dbQueue: manager.dbQueue).replaceSegments(for: transcription)
        let command = try SearchCommand.parse([
            "重要な会議", "--json", "--database", path,
        ])
        let output = try await captureStandardOutput { try await command.run() }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        let hit = try XCTUnwrap(payload.first)
        XCTAssertTrue(hit["rank"] is NSNull)
        XCTAssertTrue((hit["snippet"] as? String)?.contains("重要な会議") == true)
    }

    private func makeFixture(index: Bool = true) throws -> Fixture {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-search-\(UUID().uuidString).db")
            .path
        let manager = try DatabaseManager(path: path)
        let transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        let segments = SegmentRepository(dbQueue: manager.dbQueue)
        let meeting = Transcription(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            fileName: "Cache Review",
            rawTranscript: "Dana discussed cache invalidation.",
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 3_000,
                    endMs: 4_000,
                    speakerId: "S1",
                    speakerLabel: "Dana",
                    text: "Dana discussed cache invalidation.",
                    wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1)
                )
            ],
            status: .completed,
            sourceType: .meeting
        )
        let file = Transcription(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "notes.m4a",
            rawTranscript: "Local file cache notes.",
            wordTimestamps: [
                WordTimestamp(word: "Local", startMs: 0, endMs: 100, confidence: 1),
                WordTimestamp(word: "file", startMs: 120, endMs: 200, confidence: 1),
                WordTimestamp(word: "cache", startMs: 220, endMs: 300, confidence: 1),
                WordTimestamp(word: "notes.", startMs: 320, endMs: 500, confidence: 1),
            ],
            status: .completed,
            sourceType: .file
        )
        try transcriptions.save(meeting)
        try transcriptions.save(file)
        if index {
            try segments.replaceSegments(for: meeting)
            try segments.replaceSegments(for: file)
        }
        return Fixture(path: path, meetingID: meeting.id, fileID: file.id)
    }
}

private struct Fixture {
    let path: String
    let meetingID: UUID
    let fileID: UUID

    func cleanup() {
        for suffix in ["", "-shm", "-wal", ".migration.lock"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}

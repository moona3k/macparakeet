import XCTest
@testable import CLI
@testable import MacParakeetCore

final class SearchCommandTests: XCTestCase {
    private static let searchHitKeys: Set<String> = [
        "transcriptionId", "title", "recordedAt", "source", "seq", "startMs", "speaker", "snippet", "rank",
    ]
    private static let transcriptSegmentKeys: Set<String> = [
        "seq", "startMs", "endMs", "speaker", "text", "segmenterVersion",
    ]

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
        let payload: [[String: Any]] = try decodeJSON(output)
        let hit = try XCTUnwrap(payload.first)
        let actualKeys: Set<String> = Set(hit.keys)
        XCTAssertEqual(actualKeys, Self.searchHitKeys)
        XCTAssertEqual(hit["transcriptionId"] as? String, fixture.meetingID.uuidString)
        XCTAssertEqual(hit["source"] as? String, "meeting")
        XCTAssertEqual(hit["speaker"] as? String, "Dana")
        XCTAssertNotNil(hit["rank"] as? Double)

        let envelopeCommand = try SearchCommand.parse([
            "cache", "--envelope", "--database", fixture.path,
        ])
        let envelopeOutput = try await captureStandardOutput { try await envelopeCommand.run() }
        let envelope: [String: Any] = try decodeJSON(envelopeOutput)
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
        let first: [String: Any] = try decodeJSON(firstOutput)
        let secondOutput = try await captureStandardOutput { try await command.run() }
        let second: [String: Any] = try decodeJSON(secondOutput)
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
        let payload: [String: Any] = try decodeJSON(output)
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

    func testUntimedSearchAndTranscriptJSONEmitExplicitNullKeys() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-search-null-contract-\(UUID().uuidString).db").path
        defer { Fixture(path: path, meetingID: UUID(), fileID: UUID()).cleanup() }
        let manager = try DatabaseManager(path: path)
        let transcription = Transcription(
            fileName: "legacy.m4a",
            rawTranscript: "Legacy untimed evidence.",
            status: .completed,
            sourceType: .file
        )
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        try SegmentRepository(dbQueue: manager.dbQueue).replaceSegments(for: transcription)

        let search = try SearchCommand.parse([
            "legacy", "--json", "--database", path,
        ])
        let searchOutput = try await captureStandardOutput { try await search.run() }
        let hits: [[String: Any]] = try decodeJSON(searchOutput)
        let hit = try XCTUnwrap(hits.first)
        let searchKeys: Set<String> = Set(hit.keys)
        XCTAssertEqual(searchKeys, Self.searchHitKeys)
        XCTAssertTrue(hit["startMs"] is NSNull)
        XCTAssertTrue(hit["speaker"] is NSNull)

        let transcript = try TranscriptCommand.parse([
            transcription.id.uuidString, "--json", "--database", path,
        ])
        let transcriptOutput = try await captureStandardOutput { try await transcript.run() }
        let payload: [String: Any] = try decodeJSON(transcriptOutput)
        let rows = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        let transcriptKeys: Set<String> = Set(row.keys)
        XCTAssertEqual(transcriptKeys, Self.transcriptSegmentKeys)
        XCTAssertTrue(row["startMs"] is NSNull)
        XCTAssertTrue(row["endMs"] is NSNull)
        XCTAssertTrue(row["speaker"] is NSNull)
    }

    func testSearchValidationUsesPublicMisuseExitCode() {
        XCTAssertThrowsError(try SearchCommand.parse(["query", "--limit", "-1"])) { error in
            XCTAssertEqual(CLI.normalizedExitCode(for: error).rawValue, 2)
        }
        XCTAssertThrowsError(try TranscriptCommand.parse(["id", "--around", "1", "--around-seq", "1"])) { error in
            XCTAssertEqual(CLI.normalizedExitCode(for: error).rawValue, 2)
        }
        let oversizedDuration = String(repeating: "9", count: 100)
        XCTAssertThrowsError(try TranscriptCommand.parse(["id", "--window", oversizedDuration])) { error in
            XCTAssertEqual(CLI.normalizedExitCode(for: error).rawValue, 2)
        }
    }

    func testSearchDateOnlyBoundsUseInjectedLocalCalendarDay() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let expectedStart = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 10))
        )
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: expectedStart))
        let expectedEnd = Date(
            timeIntervalSinceReferenceDate: nextDay.timeIntervalSinceReferenceDate.nextDown
        )

        let since = try parseSearchDate("2026-07-10", boundary: .since, timeZone: timeZone)
        let until = try parseSearchDate("2026-07-10", boundary: .until, timeZone: timeZone)

        XCTAssertEqual(since, expectedStart)
        XCTAssertEqual(until, expectedEnd)

        let explicitValues = ["2026-07-10T00:00:00Z", "2026-07-10T00:00:00-04:00"]
        for explicitValue in explicitValues {
            let explicit = try parseSearchDate(explicitValue, boundary: .since, timeZone: timeZone)
            let expectedExplicit = try XCTUnwrap(ISO8601DateFormatter().date(from: explicitValue))
            XCTAssertEqual(explicit, expectedExplicit, "explicit timestamp zones must not be converted to local midnight")
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
        let payload: [[String: Any]] = try decodeJSON(output)
        let hit = try XCTUnwrap(payload.first)
        let actualKeys: Set<String> = Set(hit.keys)
        XCTAssertEqual(actualKeys, Self.searchHitKeys)
        XCTAssertTrue(hit["startMs"] is NSNull)
        XCTAssertTrue(hit["speaker"] is NSNull)
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
        let meetingSegments: [TranscriptSegmentRecord] = [
            TranscriptSegmentRecord(
                startMs: 3_000,
                endMs: 4_000,
                speakerId: "S1",
                speakerLabel: "Dana",
                text: "Dana discussed cache invalidation.",
                wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1)
            )
        ]
        let meeting = Transcription(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            fileName: "Cache Review",
            rawTranscript: "Dana discussed cache invalidation.",
            transcriptSegments: meetingSegments,
            status: .completed,
            sourceType: .meeting
        )
        let fileWords: [WordTimestamp] = [
            WordTimestamp(word: "Local", startMs: 0, endMs: 100, confidence: 1),
            WordTimestamp(word: "file", startMs: 120, endMs: 200, confidence: 1),
            WordTimestamp(word: "cache", startMs: 220, endMs: 300, confidence: 1),
            WordTimestamp(word: "notes.", startMs: 320, endMs: 500, confidence: 1),
        ]
        let file = Transcription(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "notes.m4a",
            rawTranscript: "Local file cache notes.",
            wordTimestamps: fileWords,
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

    private func decodeJSON<T>(_ output: String) throws -> T {
        let data = Data(output.utf8)
        let object: Any = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? T)
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

import XCTest
import MacParakeetCore
@testable import CLI

final class CardsCommandTests: XCTestCase {
    private static let itemKeys: Set<String> = [
        "transcriptionId", "title", "date", "durationMs", "source", "attendees",
        "cardSchemaVersion", "transcriptHash", "segmenterVersion", "promptVersion",
        "model", "generatedAt", "synopsis", "topics", "decisions", "actions",
    ]

    func testCardsListJSONHasExactKeysAndExplicitNulls() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let command = try CardsListCommand.parse([
            "--json", "--database", fixture.path,
        ])

        let output = try await captureStandardOutput { try await command.run() }
        let rows: [[String: Any]] = try decodeJSON(output)

        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(Set(row.keys), Self.itemKeys)
        }
        let meeting = try XCTUnwrap(rows.first { ($0["source"] as? String) == "meeting" })
        let attendees = try XCTUnwrap(meeting["attendees"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(attendees.first).keys), ["name", "email"])
        XCTAssertTrue(attendees[0]["email"] is NSNull)
        let decisions = try XCTUnwrap(meeting["decisions"] as? [[String: Any]])
        XCTAssertEqual(
            Set(try XCTUnwrap(decisions.first).keys),
            ["text", "seqStart", "seqEnd", "startMs", "endMs"]
        )
        XCTAssertTrue(decisions[0]["startMs"] is NSNull)
        XCTAssertTrue(decisions[0]["endMs"] is NSNull)
        let actions = try XCTUnwrap(meeting["actions"] as? [[String: Any]])
        XCTAssertEqual(
            Set(try XCTUnwrap(actions.first).keys),
            ["text", "owner", "seqStart", "seqEnd", "startMs", "endMs"]
        )
        XCTAssertTrue(actions[0]["owner"] is NSNull)

        let file = try XCTUnwrap(rows.first { ($0["source"] as? String) == "file" })
        XCTAssertTrue(file["durationMs"] is NSNull)
        XCTAssertTrue(file["attendees"] is NSNull)
        XCTAssertEqual((file["decisions"] as? [Any])?.count, 0)
        XCTAssertEqual((file["actions"] as? [Any])?.count, 0)
    }

    func testCardsListNDJSONEmitsOneCompactObjectPerLine() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let command = try CardsListCommand.parse([
            "--ndjson", "--limit", "1", "--database", fixture.path,
        ])

        let output = try await captureStandardOutput { try await command.run() }
        let lines = output.split(whereSeparator: \Character.isNewline)

        XCTAssertEqual(lines.count, 1)
        let row: [String: Any] = try decodeJSON(String(lines[0]))
        XCTAssertEqual(Set(row.keys), Self.itemKeys)
    }

    func testCardsListFiltersComposeAndUseSearchDateParsing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let command = try CardsListCommand.parse([
            "--source", "meeting",
            "--since", "2027-01-15T00:00:00Z",
            "--until", "2027-01-16T00:00:00Z",
            "--json",
            "--database", fixture.path,
        ])

        let output = try await captureStandardOutput { try await command.run() }
        let rows: [[String: Any]] = try decodeJSON(output)
        XCTAssertEqual(rows.map { $0["source"] as? String }, ["meeting"])
    }

    func testCardsGenerateRequiresExactlyOneSelection() {
        XCTAssertThrowsError(try CardsGenerateCommand.parse([]))
        XCTAssertThrowsError(try CardsGenerateCommand.parse(["--all", "--stale"]))
        XCTAssertThrowsError(try CardsGenerateCommand.parse(["--all", "abcd"]))
        XCTAssertNoThrow(try CardsGenerateCommand.parse(["--all"]))
        XCTAssertNoThrow(try CardsGenerateCommand.parse(["--stale"]))
        XCTAssertNoThrow(try CardsGenerateCommand.parse(["abcd"]))
    }

    func testCardsGenerationReportHasExactKeysAndExplicitNulls() throws {
        var report = CardsGenerationReport(selection: "stale", selected: 3)
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "selection", "selected", "processed", "generated", "skipped", "failed",
                "promptTokens", "completionTokens", "totalTokens", "estimatedCostUSD", "failures",
            ]
        )
        for key in ["promptTokens", "completionTokens", "totalTokens", "estimatedCostUSD"] {
            XCTAssertTrue(object[key] is NSNull)
        }
        XCTAssertEqual(report.exitCode, .success)
        report.failed = 1
        XCTAssertEqual(report.exitCode, .failure)
    }

    func testRootParserRoutesCardsSubcommands() throws {
        XCTAssertTrue(try CLI.parseAsRoot(["cards", "list", "--json"]) is CardsListCommand)
        XCTAssertTrue(try CLI.parseAsRoot(["cards", "generate", "--stale"]) is CardsGenerateCommand)
    }

    private func makeFixture() throws -> Fixture {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cards-\(UUID().uuidString).db").path
        let manager = try DatabaseManager(path: path)
        let transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        let cards = CardRepository(dbQueue: manager.dbQueue)
        let meetingDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T12:00:00Z"))
        let meeting = Transcription(
            id: UUID(),
            createdAt: meetingDate,
            fileName: "Planning",
            durationMs: 60_000,
            rawTranscript: "Ship it.",
            status: .completed,
            sourceType: .meeting,
            calendarEventSnapshot: MeetingCalendarSnapshot(
                confidence: .confirmed,
                eventIdentifier: "event",
                title: "Planning",
                scheduledStartAt: meetingDate,
                scheduledEndAt: meetingDate.addingTimeInterval(60),
                attendees: [MeetingCalendarPerson(name: "Dana", email: nil)]
            )
        )
        let file = Transcription(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "notes.m4a",
            durationMs: nil,
            rawTranscript: "File notes.",
            status: .completed,
            sourceType: .file
        )
        for transcription in [meeting, file] {
            try transcriptions.save(transcription)
            try cards.save(
                Card(
                    transcriptionId: transcription.id,
                    cardSchemaVersion: 1,
                    transcriptHash: "hash-\(transcription.id)",
                    segmenterVersion: 2,
                    promptVersion: "knowledge-card-v1",
                    model: "stub-model",
                    generatedAt: meetingDate,
                    synopsis: "A useful card.",
                    topics: ["release"],
                    decisions: [
                        CardDecision(text: "Ship it", seqStart: 0, seqEnd: 0, startMs: nil, endMs: nil)
                    ],
                    actions: [
                        CardAction(text: "Verify", owner: nil, seqStart: 0, seqEnd: 0, startMs: nil, endMs: nil)
                    ]
                ))
        }
        return Fixture(path: path)
    }
}

private struct Fixture {
    let path: String

    func cleanup() {
        for suffix in ["", "-shm", "-wal", ".migration.lock"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}

private func decodeJSON<T>(_ string: String) throws -> T {
    try JSONSerialization.jsonObject(with: Data(string.utf8)) as! T
}

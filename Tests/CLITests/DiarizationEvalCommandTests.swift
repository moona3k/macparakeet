import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class DiarizationEvalCommandTests: XCTestCase {
    func testParsesScoringFlags() throws {
        let command = try DiarizationEvalCommand.parse([
            "/tmp/fixtures",
            "--json",
            "--collar-ms",
            "250",
            "--ignore-overlap",
        ])

        XCTAssertEqual(command.fixturesDir, "/tmp/fixtures")
        XCTAssertTrue(command.json)
        XCTAssertEqual(command.collarMs, 250)
        XCTAssertTrue(command.ignoreOverlap)
    }

    func testRejectsNegativeCollar() {
        XCTAssertThrowsError(try DiarizationEvalCommand.parse([
            "/tmp/fixtures",
            "--collar-ms",
            "-1",
        ]))
    }

    func testEvaluateRunsDefaultExactMinAndMaxVariantsWithoutModels() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("two-remote-speakers", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("audio.wav"))
        try Data().write(to: fixture.appendingPathComponent("system.wav"))
        try """
        {"expectedRemoteSpeakers": 2}
        """.data(using: .utf8)!.write(to: fixture.appendingPathComponent("expected.json"))
        try """
        SPEAKER fixture 1 0.000 1.000 <NA> <NA> ref_a <NA> <NA>
        SPEAKER fixture 1 1.000 1.000 <NA> <NA> ref_b <NA> <NA>
        """.write(to: fixture.appendingPathComponent("reference.rttm"), atomically: true, encoding: .utf8)

        let service = RecordingEvalDiarizationService(result: MacParakeetDiarizationResult(
            segments: [
                SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1_000),
                SpeakerSegment(speakerId: "S2", startMs: 1_000, endMs: 2_000),
            ],
            speakerCount: 2,
            speakers: []
        ))

        let report = try await DiarizationEvalCommand.evaluate(
            fixturesDir: root.path,
            scoringOptions: DiarizationScoringOptions(collarMs: 100, skipOverlap: true),
            service: service
        )

        XCTAssertNil(report.fixturesDir)
        XCTAssertEqual(report.scoringOptions, DiarizationScoringOptions(collarMs: 100, skipOverlap: true))
        XCTAssertEqual(report.fixtureCount, 1)
        XCTAssertEqual(report.runCount, 4)
        XCTAssertEqual(report.fixtures[0].fixture, "two-remote-speakers")
        XCTAssertNil(report.fixtures[0].audioFile)
        XCTAssertEqual(report.fixtures[0].runs.map(\.variant), [
            "default",
            "exact(2)",
            "min(2)",
            "max(2)",
        ])
        XCTAssertTrue(report.fixtures[0].runs.allSatisfy { $0.qualityReport != nil })
        XCTAssertTrue(report.fixtures[0].runs.allSatisfy { $0.der?.collarMs == 100 })
        XCTAssertTrue(report.fixtures[0].runs.allSatisfy { $0.der?.skipOverlap == true })

        let recordedURLs = await service.audioURLs
        XCTAssertEqual(recordedURLs.map(\.lastPathComponent), Array(repeating: "system.wav", count: 4))
        let recordedOptions = await service.options
        XCTAssertEqual(recordedOptions.map(\.speakerCountHint), [
            nil,
            SpeakerCountHint(exact: 2),
            SpeakerCountHint(minimum: 2),
            SpeakerCountHint(maximum: 2),
        ])
    }

    func testEvaluateSerializesPerRunDiarizerErrors() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("fixture-001", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("audio.wav"))

        let service = RecordingEvalDiarizationService(error: TestEvalError())

        let report = try await DiarizationEvalCommand.evaluate(
            fixturesDir: root.path,
            scoringOptions: .default,
            service: service
        )

        XCTAssertEqual(report.fixtureCount, 1)
        XCTAssertEqual(report.runCount, 1)
        XCTAssertEqual(report.fixtures[0].runs[0].variant, "default")
        XCTAssertEqual(report.fixtures[0].runs[0].error, "eval failure")
        XCTAssertNil(report.fixtures[0].runs[0].qualityReport)
    }

    func testEvaluateJSONOmitsRootPathAndAudioFilename() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("fixture-001", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("secret-meeting-name.wav"))

        let service = RecordingEvalDiarizationService(result: MacParakeetDiarizationResult(
            segments: [SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1_000)],
            speakerCount: 1,
            speakers: []
        ))

        let report = try await DiarizationEvalCommand.evaluate(
            fixturesDir: root.path,
            scoringOptions: .default,
            service: service
        )
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains(root.path))
        XCTAssertFalse(json.contains("secret-meeting-name.wav"))
        XCTAssertFalse(json.contains("fixturesDir"))
        XCTAssertFalse(json.contains("audioFile"))
    }

    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-diarization-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

private actor RecordingEvalDiarizationService: DiarizationServiceProtocol {
    private let result: MacParakeetDiarizationResult
    private let error: Error?
    var audioURLs: [URL] = []
    var options: [DiarizationOptions] = []

    init(
        result: MacParakeetDiarizationResult = MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: []),
        error: Error? = nil
    ) {
        self.result = result
        self.error = error
    }

    func diarize(audioURL: URL, options: DiarizationOptions) async throws -> MacParakeetDiarizationResult {
        audioURLs.append(audioURL)
        self.options.append(options)
        if let error {
            throw error
        }
        return result
    }

    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func isReady() async -> Bool {
        true
    }

    func hasCachedModels() async -> Bool {
        true
    }
}

private struct TestEvalError: LocalizedError {
    var errorDescription: String? {
        "eval failure"
    }
}

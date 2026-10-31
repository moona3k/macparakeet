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
        XCTAssertThrowsError(
            try DiarizationEvalCommand.parse([
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

        let service = RecordingEvalDiarizationService(
            result: MacParakeetDiarizationResult(
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
        XCTAssertEqual(report.fixtures[0].fixture, "fixture-001")
        XCTAssertNil(report.fixtures[0].audioFile)
        XCTAssertEqual(
            report.fixtures[0].runs.map(\.variant),
            [
                "default",
                "exact(2)",
                "min(2)",
                "max(2)",
            ])
        XCTAssertTrue(report.fixtures[0].runs.allSatisfy { $0.qualityReport != nil })
        XCTAssertTrue(report.fixtures[0].runs.allSatisfy { $0.der?.collarMs == 100 })
        XCTAssertTrue(report.fixtures[0].runs.allSatisfy { $0.der?.skipOverlap == true })
        XCTAssertTrue(report.fixtures[0].runs.allSatisfy { $0.qualityReport?.diarizedAudioSource == .system })
        let runs = report.fixtures[0].runs
        XCTAssertEqual(runs.map(\.requestedSpeakers), [nil, 2, nil, nil])
        XCTAssertEqual(
            runs.map(\.requestedSpeakerHint),
            [
                nil, SpeakerCountHint(exact: 2), SpeakerCountHint(minimum: 2), SpeakerCountHint(maximum: 2),
            ])

        let recordedURLs = await service.audioURLs
        XCTAssertEqual(recordedURLs.map(\.lastPathComponent), Array(repeating: "system.wav", count: 4))
        let recordedConstraints = await service.speakerConstraints
        XCTAssertEqual(
            recordedConstraints,
            [
                nil,
                .exact(2),
                .range(min: 2, max: nil),
                .range(min: nil, max: 2),
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
        XCTAssertEqual(report.fixtures[0].runs[0].error, "diarization_failed")
        XCTAssertNil(report.fixtures[0].runs[0].qualityReport)
    }

    func testEvaluateJSONOmitsRootPathAndAudioFilename() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("Alice-private-meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("secret-meeting-name.wav"))

        let service = RecordingEvalDiarizationService(
            result: MacParakeetDiarizationResult(
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
        XCTAssertFalse(json.contains("Alice-private-meeting"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["schemaVersion", "scoringOptions", "fixtureCount", "runCount", "fixtures"])
    }

    func testTimingOnlyFixtureExercisesExperimentalAssignmentWarnings() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("audio.wav"))
        try """
        [{"startMs":0,"endMs":100},{"startMs":600,"endMs":650},
         {"startMs":700,"endMs":750},{"startMs":2000,"endMs":2100}]
        """.write(to: fixture.appendingPathComponent("words.json"), atomically: true, encoding: .utf8)
        let service = RecordingEvalDiarizationService(
            result: MacParakeetDiarizationResult(
                segments: [SpeakerSegment(speakerId: "private-provider-name", startMs: 0, endMs: 500)],
                speakerCount: 1, speakers: []
            ))

        let report = try await DiarizationEvalCommand.evaluate(
            fixturesDir: root.path, scoringOptions: .default, service: service)

        let quality = try XCTUnwrap(report.fixtures.first?.runs.first?.qualityReport)
        XCTAssertEqual(quality.assignmentSummary.directOverlapWords, 1)
        XCTAssertEqual(quality.assignmentSummary.fallbackNearestWords, 2)
        XCTAssertEqual(quality.assignmentSummary.unassignedWords, 1)
        let warning = try XCTUnwrap(quality.warnings.first { $0.kind == .highFallbackAssignmentRate })
        XCTAssertEqual(warning.observed, 0.5)
        XCTAssertEqual(warning.denominator?.count, 4)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("private-provider-name"))
        XCTAssertFalse(json.contains("startMs"), "Report contains aggregates, not word timings")
    }

    func testFailedRangeRunsPreserveHintWithoutClaimingAnExactCountOrLeakingErrors() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("private-name")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("audio.wav"))
        try "{\"minimumRemoteSpeakers\":2,\"maximumRemoteSpeakers\":3}"
            .write(to: fixture.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)
        let service = RecordingEvalDiarizationService(
            error: NSError(
                domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Private Alice at /tmp/secret.wav"]
            ))

        let report = try await DiarizationEvalCommand.evaluate(
            fixturesDir: root.path, scoringOptions: .default, service: service)

        let runs = report.fixtures[0].runs
        XCTAssertEqual(runs.map(\.variant), ["default", "min(2)", "max(3)"])
        XCTAssertTrue(runs.allSatisfy { $0.requestedSpeakers == nil })
        XCTAssertEqual(
            runs.map(\.requestedSpeakerHint), [nil, SpeakerCountHint(minimum: 2), SpeakerCountHint(maximum: 3)])
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("Private Alice"))
        XCTAssertFalse(json.contains("/tmp/secret.wav"))
        XCTAssertFalse(json.contains("private-name"))
        XCTAssertTrue(runs.allSatisfy { $0.error == "diarization_failed" })
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let fixtures = try XCTUnwrap(payload["fixtures"] as? [[String: Any]])
        let encodedRuns = try XCTUnwrap(fixtures[0]["runs"] as? [[String: Any]])
        XCTAssertNil(encodedRuns[1]["requestedSpeakers"])
        XCTAssertEqual((encodedRuns[1]["requestedSpeakerHint"] as? [String: Int])?["minimum"], 2)
        XCTAssertEqual((encodedRuns[2]["requestedSpeakerHint"] as? [String: Int])?["maximum"], 3)
        XCTAssertNil(encodedRuns[1]["qualityReport"])
        XCTAssertNil(encodedRuns[1]["detectedSpeakers"])
    }

    func testCancellationStopsEvaluationInsteadOfBecomingAPerRunFailure() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("audio.wav"))
        try "{\"expectedRemoteSpeakers\":2}"
            .write(to: fixture.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)
        let service = RecordingEvalDiarizationService(error: CancellationError())

        do {
            _ = try await DiarizationEvalCommand.evaluate(
                fixturesDir: root.path, scoringOptions: .default, service: service)
            XCTFail("Cancellation must leave the evaluation")
        } catch is CancellationError {}
        let urls = await service.audioURLs
        XCTAssertEqual(urls.count, 1)
    }

    func testNoScoredReferenceTimeOmitsDERInsteadOfReportingPerfectScore() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("audio.wav"))
        try "SPEAKER fixture 1 0 1 <NA> <NA> A <NA> <NA>"
            .write(to: fixture.appendingPathComponent("reference.rttm"), atomically: true, encoding: .utf8)

        let report = try await DiarizationEvalCommand.evaluate(
            fixturesDir: root.path, scoringOptions: DiarizationScoringOptions(collarMs: 4_000),
            service: RecordingEvalDiarizationService()
        )

        XCTAssertTrue(report.fixtures[0].referenceAvailable)
        XCTAssertNil(report.fixtures[0].runs[0].der)
        XCTAssertNil(report.fixtures[0].runs[0].coverage)
    }

    func testInvalidExpectedCountIsRejectedBeforeDiarization() async throws {
        let root = try makeFixtureRoot()
        let fixture = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data().write(to: fixture.appendingPathComponent("audio.wav"))
        try "{\"expectedRemoteSpeakers\":0}"
            .write(to: fixture.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)
        let service = RecordingEvalDiarizationService()

        do {
            _ = try await DiarizationEvalCommand.evaluate(
                fixturesDir: root.path, scoringOptions: .default, service: service)
            XCTFail("Invalid fixture metadata must not silently run unconstrained")
        } catch is DiarizationOptionsValidationError {}
        let urls = await service.audioURLs
        XCTAssertTrue(urls.isEmpty)
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
    var speakerConstraints: [SpeakerDiarizationConstraint?] = []

    init(
        result: MacParakeetDiarizationResult = MacParakeetDiarizationResult(
            segments: [], speakerCount: 0, speakers: []),
        error: Error? = nil
    ) {
        self.result = result
        self.error = error
    }

    func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        audioURLs.append(audioURL)
        speakerConstraints.append(speakerConstraint)
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

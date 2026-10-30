import XCTest
@testable import MacParakeetCore

final class DiarizationQualityReportTests: XCTestCase {
    func testBuildsCountsAndStructuredWarnings() throws {
        let summary = WordSpeakerAssignmentSummary(
            totalWords: 10,
            directOverlapWords: 2,
            fallbackNearestWords: 4,
            sourceOnlyWords: 4,
            unassignedWords: 0,
            fallbackToleranceMs: 250,
            ambiguityMarginMs: 150,
            minFallbackQualityScore: 0.60
        )
        let report = DiarizationQualityReport(
            transcriptionSourceType: .meeting,
            diarizedAudioSource: .system,
            requestedSpeakerHint: SpeakerCountHint(exact: 3),
            diarizationResult: MacParakeetDiarizationResult(
                segments: [
                    SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 500),
                    SpeakerSegment(speakerId: "S1", startMs: 600, endMs: 800),
                    SpeakerSegment(speakerId: "S2", startMs: 800, endMs: 1_200),
                ],
                speakerCount: 2,
                speakers: [
                    SpeakerInfo(id: "S1", label: "Speaker 1"),
                    SpeakerInfo(id: "S2", label: "Speaker 2"),
                ]
            ),
            assignmentSummary: summary
        )

        XCTAssertEqual(report.transcriptionSourceType, .meeting)
        XCTAssertEqual(report.diarizedAudioSource, .system)
        XCTAssertEqual(report.requestedSpeakerHint, SpeakerCountHint(exact: 3))
        XCTAssertEqual(report.detectedSpeakerCount, 2)
        XCTAssertEqual(report.rawDiarizationSegmentCount, 3)
        XCTAssertEqual(report.segmentsPerSpeaker, ["S1": 2, "S2": 1])
        XCTAssertEqual(report.speakingTimeMsPerSpeaker, ["S1": 700, "S2": 400])

        let warningKinds = Set(report.warnings.map(\.kind))
        XCTAssertEqual(
            warningKinds,
            [
                .speakerCountBelowHint,
                .highFallbackAssignmentRate,
            ])

        let fallbackWarning = try XCTUnwrap(report.warnings.first { $0.kind == .highFallbackAssignmentRate })
        XCTAssertEqual(fallbackWarning.observed, 4.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(fallbackWarning.threshold, 0.3, accuracy: 0.0001)
        XCTAssertEqual(
            fallbackWarning.denominator,
            DiarizationQualityWarningDenominator(name: "eligibleDiarizedWords", count: 6)
        )
    }

    func testEncodedPayloadDoesNotIncludeTranscriptPathsURLsOrSpeakerLabels() throws {
        let report = DiarizationQualityReport(
            transcriptionSourceType: .file,
            diarizedAudioSource: nil,
            requestedSpeakerHint: nil,
            diarizationResult: MacParakeetDiarizationResult(
                segments: [
                    SpeakerSegment(speakerId: "Alice Example", startMs: 0, endMs: 500)
                ],
                speakerCount: 1,
                speakers: [
                    SpeakerInfo(id: "Alice Example", label: "Alice Example")
                ]
            ),
            assignmentSummary: WordSpeakerAssignmentSummary(
                totalWords: 1,
                directOverlapWords: 1,
                fallbackNearestWords: 0,
                sourceOnlyWords: 0,
                unassignedWords: 0,
                fallbackToleranceMs: 250,
                ambiguityMarginMs: 150,
                minFallbackQualityScore: 0.60
            )
        )

        let data = try JSONEncoder().encode(report)
        let payload = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(payload.contains("private transcript"))
        XCTAssertFalse(payload.contains("/tmp/secret.wav"))
        XCTAssertFalse(payload.contains("https://example.com/watch"))
        XCTAssertFalse(payload.contains("Alice Example"))
        XCTAssertEqual(report.segmentsPerSpeaker, ["S1": 1])
    }

    func testSourceOnlyWordsCannotDiluteFallbackWarning() throws {
        for sourceOnly in [0, 90] {
            let report = makeReport(direct: 4, fallback: 4, sourceOnly: sourceOnly, unassigned: 2)
            let warning = try XCTUnwrap(report.warnings.first { $0.kind == .highFallbackAssignmentRate })
            XCTAssertEqual(warning.observed, 0.4, accuracy: 0.0001)
            XCTAssertEqual(warning.denominator?.count, 10)
        }
        XCTAssertTrue(makeReport(direct: 0, fallback: 0, sourceOnly: 90, unassigned: 0).warnings.isEmpty)
    }

    private func makeReport(direct: Int, fallback: Int, sourceOnly: Int, unassigned: Int) -> DiarizationQualityReport {
        DiarizationQualityReport(
            transcriptionSourceType: .file, diarizedAudioSource: nil, requestedSpeakerHint: nil,
            diarizationResult: MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: []),
            assignmentSummary: WordSpeakerAssignmentSummary(
                totalWords: direct + fallback + sourceOnly + unassigned,
                directOverlapWords: direct, fallbackNearestWords: fallback,
                sourceOnlyWords: sourceOnly, unassignedWords: unassigned,
                fallbackToleranceMs: 250, ambiguityMarginMs: 150, minFallbackQualityScore: 0.60
            )
        )
    }
}

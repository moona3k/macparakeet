import XCTest
@testable import MacParakeetCore

final class DiarizationMetricsTests: XCTestCase {

    func testPerfectMatchHasZeroDER() {
        let reference = [
            segment("A", 0, 1000),
            segment("B", 1000, 2000),
        ]
        let hypothesis = [
            segment("H1", 0, 1000),
            segment("H2", 1000, 2000),
        ]

        let result = DiarizationMetrics.der(reference: reference, hypothesis: hypothesis)

        XCTAssertEqual(result.missedMs, 0)
        XCTAssertEqual(result.falseAlarmMs, 0)
        XCTAssertEqual(result.confusionMs, 0)
        XCTAssertEqual(result.totalReferenceMs, 2000)
        XCTAssertEqual(result.der, 0, accuracy: 0.0001)
    }

    func testCompleteMissCountsAllReferenceSpeechAsMissed() {
        let reference = [segment("A", 0, 1200)]

        let result = DiarizationMetrics.der(reference: reference, hypothesis: [])

        XCTAssertEqual(result.missedMs, 1200)
        XCTAssertEqual(result.falseAlarmMs, 0)
        XCTAssertEqual(result.confusionMs, 0)
        XCTAssertEqual(result.totalReferenceMs, 1200)
        XCTAssertEqual(result.der, 1, accuracy: 0.0001)
    }

    func testPureFalseAlarmCountsHypothesisOutsideReferenceSpeech() {
        let reference = [segment("A", 0, 1000)]
        let hypothesis = [segment("H1", 0, 2000)]

        let result = DiarizationMetrics.der(reference: reference, hypothesis: hypothesis)

        XCTAssertEqual(result.missedMs, 0)
        XCTAssertEqual(result.falseAlarmMs, 1000)
        XCTAssertEqual(result.confusionMs, 0)
        XCTAssertEqual(result.totalReferenceMs, 1000)
        XCTAssertEqual(result.der, 1, accuracy: 0.0001)
    }

    func testSpeakerConfusionCountsCoveredSpeechWithWrongMappedSpeaker() {
        let reference = [
            segment("A", 0, 1000),
            segment("B", 1000, 2000),
        ]
        let hypothesis = [
            segment("H1", 0, 2000),
        ]

        let result = DiarizationMetrics.der(reference: reference, hypothesis: hypothesis)

        XCTAssertEqual(result.missedMs, 0)
        XCTAssertEqual(result.falseAlarmMs, 0)
        XCTAssertEqual(result.confusionMs, 1000)
        XCTAssertEqual(result.totalReferenceMs, 2000)
        XCTAssertEqual(result.der, 0.5, accuracy: 0.0001)
    }

    func testSpeakerCountDeltaReportsOverSplitAndUnderSplit() {
        let reference = [
            segment("A", 0, 1000),
            segment("B", 1000, 2000),
        ]
        let overSplit = [
            segment("H1", 0, 700),
            segment("H2", 700, 1400),
            segment("H3", 1400, 2000),
        ]
        let underSplit = [
            segment("H1", 0, 2000),
        ]

        XCTAssertEqual(
            DiarizationMetrics.speakerCountDelta(reference: reference, hypothesis: overSplit),
            1
        )
        XCTAssertEqual(
            DiarizationMetrics.speakerCountDelta(reference: reference, hypothesis: underSplit),
            -1
        )
    }

    func testCoverageCountsFractionOfReferenceSpeechCoveredByAnyHypothesis() {
        let reference = [
            segment("A", 0, 1000),
            segment("B", 2000, 3000),
        ]
        let hypothesis = [
            segment("H1", 500, 1500),
            segment("H2", 2500, 2600),
        ]

        let coverage = DiarizationMetrics.coverage(reference: reference, hypothesis: hypothesis)

        XCTAssertEqual(coverage, 0.3, accuracy: 0.0001)
    }

    func testCoverageIsZeroWhenReferenceHasNoSpeech() {
        let coverage = DiarizationMetrics.coverage(
            reference: [],
            hypothesis: [segment("H1", 0, 1000)]
        )

        XCTAssertEqual(coverage, 0, accuracy: 0.0001)
    }

    private func segment(_ speakerId: String, _ startMs: Int, _ endMs: Int) -> LabeledSegment {
        LabeledSegment(speakerId: speakerId, startMs: startMs, endMs: endMs)
    }
}

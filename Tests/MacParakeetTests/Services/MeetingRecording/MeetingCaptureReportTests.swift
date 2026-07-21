import XCTest
@testable import MacParakeetCore

final class MeetingCaptureReportTests: XCTestCase {
    func testSevereDualSourceShortfallIsPartial() throws {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 1_000),
            system: track(writtenDurationMs: 1_000)
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: alignment,
            elapsedDurationMs: 100_000
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.elapsedDurationMs, 100_000)
        XCTAssertEqual(report.capturedDurationMs, 1_000)
        XCTAssertEqual(report.sources.map(\.source), [.microphone, .system])
        XCTAssertEqual(report.sources.map(\.writtenDurationMs), [1_000, 1_000])
        XCTAssertEqual(report.sources.map(\.status), [.coverageShortfall, .coverageShortfall])
        XCTAssertEqual(try XCTUnwrap(report.source(for: .microphone)?.coverageRatio), 0.01, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(report.source(for: .system)?.coverageRatio), 0.01, accuracy: 0.0001)
        XCTAssertFalse(report.captureFailed)
        XCTAssertTrue(report.interruptedSources.isEmpty)
    }

    func testCoverageBelowMinimumRatioIsPartial() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 9_000),
            system: nil
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: alignment,
            elapsedDurationMs: 12_000,
            policy: MeetingCaptureReport.Policy(minimumCoverageRatio: 0.9)
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.sources.map(\.status), [.coverageShortfall])
        XCTAssertEqual(report.sources.map(\.source), [.microphone])
    }

    func testShortRecordingBelowCoverageThresholdIsPartial() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 200),
            system: nil
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: alignment,
            elapsedDurationMs: 4_000,
            policy: MeetingCaptureReport.Policy(minimumCoverageRatio: 0.9)
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.source(for: .microphone)?.status, .coverageShortfall)
        XCTAssertEqual(report.source(for: .microphone)?.coverageRatio, 0.05)
    }

    func testCoverageAboveMinimumRatioIsHealthy() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 92_000),
            system: nil
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: alignment,
            elapsedDurationMs: 100_000,
            policy: MeetingCaptureReport.Policy(minimumCoverageRatio: 0.9)
        )

        XCTAssertEqual(report.quality, .healthy)
        XCTAssertEqual(report.source(for: .microphone)?.status, .complete)
        XCTAssertEqual(report.source(for: .microphone)?.coverageRatio, 0.92)
    }

    func testCaptureFailureIsPartialDespiteHighCoverage() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 9_000),
            system: nil
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: alignment,
            elapsedDurationMs: 10_000,
            captureFailed: true
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.source(for: .microphone)?.status, .captureFailed)
        XCTAssertTrue(report.captureFailed)
    }

    func testExplicitInterruptionIsPartialDespiteHighCoverage() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 9_000),
            system: nil
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: alignment,
            elapsedDurationMs: 10_000,
            interruptedSources: [.microphone]
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.sources.map(\.status), [.interrupted])
        XCTAssertEqual(report.interruptedSources, [.microphone])
    }

    func testCapturedDurationIncludesSourceStartOffsetAndIgnoresUnselectedSource() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 10_000, startOffsetMs: 250),
            system: track(writtenDurationMs: 90_000)
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: alignment,
            elapsedDurationMs: 10_250
        )

        XCTAssertEqual(report.quality, .healthy)
        XCTAssertEqual(report.capturedDurationMs, 10_250)
        XCTAssertEqual(report.sources.map(\.source), [.microphone])
    }

    func testTimelinePaddingExtendsPlayableDurationWithoutInflatingCoverage() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(
                writtenDurationMs: 2_000,
                timelineDurationMs: 4_000
            ),
            system: nil
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: alignment,
            elapsedDurationMs: 4_000,
            policy: MeetingCaptureReport.Policy(minimumCoverageRatio: 0.9)
        )

        XCTAssertEqual(report.capturedDurationMs, 4_000)
        XCTAssertEqual(report.source(for: .microphone)?.writtenDurationMs, 2_000)
        XCTAssertEqual(report.source(for: .microphone)?.coverageRatio, 0.5)
        XCTAssertEqual(report.source(for: .microphone)?.status, .coverageShortfall)
    }

    func testMissingSelectedSourceIsUnavailable() {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(writtenDurationMs: 20_000),
                system: nil
            ),
            elapsedDurationMs: 20_000
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.source(for: .microphone)?.status, .complete)
        XCTAssertEqual(report.source(for: .system)?.status, .unavailable)
        XCTAssertEqual(report.source(for: .system)?.writtenDurationMs, 0)
    }

    func testPlaybackFallbackMarksOtherwiseCompleteCapturePartial() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 10_000),
            system: track(writtenDurationMs: 10_000)
        )

        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: alignment,
            elapsedDurationMs: 10_000,
            playbackFallbackSource: .system
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.sources.map(\.status), [.complete, .complete])
        XCTAssertEqual(report.playbackFallbackSource, .system)
    }

    func testPlaybackFallbackMarkerIsIgnoredForSingleSourceMode() {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(writtenDurationMs: 10_000),
                system: nil
            ),
            elapsedDurationMs: 10_000,
            playbackFallbackSource: .microphone
        )

        XCTAssertEqual(report.quality, .healthy)
        XCTAssertNil(report.playbackFallbackSource)
    }

    func testLegacyReportWithoutPlaybackFallbackDecodesAsNil() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(writtenDurationMs: 10_000),
                system: nil
            ),
            elapsedDurationMs: 10_000
        )
        let encoded = try JSONEncoder().encode(report)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "playbackFallbackSource")

        let decoded = try JSONDecoder().decode(
            MeetingCaptureReport.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.playbackFallbackSource)
        XCTAssertEqual(decoded.quality, .healthy)
    }

    private func track(
        writtenDurationMs: Int,
        timelineDurationMs: Int? = nil,
        startOffsetMs: Int = 0,
        sampleRate: Double = 48_000
    ) -> MeetingSourceAlignment.Track {
        MeetingSourceAlignment.Track(
            firstHostTime: 100,
            lastHostTime: 200,
            startOffsetMs: startOffsetMs,
            writtenFrameCount: Int64((Double(writtenDurationMs) / 1_000 * sampleRate).rounded()),
            timelineFrameCount: timelineDurationMs.map {
                Int64((Double($0) / 1_000 * sampleRate).rounded())
            },
            sampleRate: sampleRate
        )
    }
}

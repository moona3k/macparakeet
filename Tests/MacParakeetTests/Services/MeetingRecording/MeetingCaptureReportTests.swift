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

    func testCoverageShortfallPrecedesSilentStatus() {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(writtenDurationMs: 100_000),
                system: track(writtenDurationMs: 1_000)
            ),
            elapsedDurationMs: 100_000,
            silentSources: [.system]
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.source(for: .microphone)?.status, .complete)
        XCTAssertEqual(report.source(for: .system)?.status, .coverageShortfall)
    }

    func testInterruptionAndCaptureFailurePrecedeSilentStatus() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: track(writtenDurationMs: 10_000),
            system: track(writtenDurationMs: 10_000)
        )

        let interrupted = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: alignment,
            elapsedDurationMs: 10_000,
            interruptedSources: [.system],
            silentSources: [.system]
        )
        let failed = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: alignment,
            elapsedDurationMs: 10_000,
            silentSources: [.system],
            captureFailed: true
        )

        XCTAssertEqual(interrupted.quality, .partial)
        XCTAssertEqual(failed.quality, .partial)
        XCTAssertEqual(interrupted.source(for: .system)?.status, .interrupted)
        XCTAssertEqual(failed.source(for: .system)?.status, .captureFailed)
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
            elapsedDurationMs: 20_000,
            silentSources: [.system]
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
            silentSources: [.system],
            playbackFallbackSource: .system
        )

        XCTAssertEqual(report.quality, .partial)
        XCTAssertEqual(report.sources.map(\.status), [.complete, .silent])
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

    func testCompleteSilentCaptureIsHealthyAndRoundTripsThroughCodable() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(writtenDurationMs: 30_000),
                system: track(writtenDurationMs: 30_000)
            ),
            elapsedDurationMs: 30_000,
            silentSources: [.system]
        )

        XCTAssertEqual(report.quality, .healthy)
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MeetingCaptureReport.self, from: encoded)

        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.quality, .healthy)
        XCTAssertEqual(decoded.source(for: .system)?.status, .silent)
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
        XCTAssertEqual(decoded.source(for: .microphone)?.status, .complete)
    }

    func testLegacySilenceOnlyPartialReportDecodesHealthyWithoutChangingDiagnostics() throws {
        let object = legacySilentReport()
        let decoded = try JSONDecoder().decode(
            MeetingCaptureReport.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.quality, .healthy)
        XCTAssertEqual(decoded.source(for: .system)?.status, .silent)
        XCTAssertEqual(decoded.source(for: .system)?.writtenDurationMs, 30_000)
        var expected = object
        expected["quality"] = "healthy"
        let reencoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        XCTAssertEqual(reencoded as NSDictionary, expected as NSDictionary)
    }

    func testLegacySilentStatusCannotHideCoverageShortfallOnDecode() throws {
        var object = legacySilentReport()
        var sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
        sources[1]["writtenDurationMs"] = 26_999
        sources[1]["coverageRatio"] = Double(26_999) / 30_000
        object["sources"] = sources

        let incomplete = try JSONDecoder().decode(
            MeetingCaptureReport.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(incomplete.quality, .partial)
        XCTAssertEqual(incomplete.source(for: .system)?.status, .silent)

        sources[1]["writtenDurationMs"] = 27_000
        sources[1]["coverageRatio"] = 0.9
        object["sources"] = sources
        let sufficientCoverage = try JSONDecoder().decode(
            MeetingCaptureReport.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(sufficientCoverage.quality, .healthy)
    }

    func testLegacySilentReportRetainsIndependentDegradationOnDecode() throws {
        let legacy = legacySilentReport()
        let originalSources = try XCTUnwrap(legacy["sources"] as? [[String: Any]])
        var cases: [[String: Any]] = []
        for status in ["coverage_shortfall", "interrupted", "unavailable", "capture_failed"] {
            var object = legacy
            var sources = originalSources
            sources[0]["status"] = status
            object["sources"] = sources
            cases.append(object)
        }
        let independentDegradations: [(String, Any)] = [
            ("captureFailed", true),
            ("interruptedSources", ["system"]),
            ("playbackFallbackSource", "microphone"),
            ("sources", [originalSources[1]]),
        ]
        for (key, value) in independentDegradations {
            var object = legacy
            object[key] = value
            cases.append(object)
        }

        for object in cases {
            let decoded = try JSONDecoder().decode(
                MeetingCaptureReport.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            XCTAssertEqual(decoded.quality, .partial, "\(object)")
        }
    }

    func testPartialReportWithoutSilenceIsNotReclassifiedOnDecode() throws {
        var object = legacySilentReport()
        var sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
        sources[1]["status"] = "complete"
        object["sources"] = sources

        let decoded = try JSONDecoder().decode(
            MeetingCaptureReport.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.quality, .partial)
    }

    func testLegacySilentReportStillRequiresNonoptionalFields() throws {
        var object = legacySilentReport()
        object.removeValue(forKey: "captureFailed")

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MeetingCaptureReport.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("Expected missing captureFailed, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "captureFailed")
        }
    }

    private func legacySilentReport() -> [String: Any] {
        [
            "quality": "partial",
            "sourceMode": "microphone_and_system",
            "elapsedDurationMs": 30_000,
            "capturedDurationMs": 30_000,
            "sources": [
                [
                    "source": "microphone",
                    "writtenDurationMs": 30_000,
                    "coverageRatio": 1.0,
                    "status": "complete",
                ],
                [
                    "source": "system",
                    "writtenDurationMs": 30_000,
                    "coverageRatio": 1.0,
                    "status": "silent",
                ],
            ],
            "interruptedSources": [],
            "captureFailed": false,
        ]
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

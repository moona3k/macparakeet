import XCTest
import MacParakeetCore
@testable import MacParakeet

final class MeetingPartialCapturePresentationTests: XCTestCase {
    func testPartialMeetingExplainsCapturedAndElapsedDuration() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 68_000),
                system: track(durationMs: 68_000)
            ),
            elapsedDurationMs: 2_355_000
        )
        let transcription = Transcription(
            fileName: "Design Review",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(MeetingPartialCapturePresentation.make(for: transcription))

        XCTAssertEqual(presentation.badgeText, "Partial audio")
        XCTAssertEqual(presentation.title, "Partial meeting audio")
        XCTAssertEqual(
            presentation.message,
            "Playback is 1:08 from a 39:15 session. Microphone captured 1:08. System audio captured 1:08."
        )
    }

    func testPartialMeetingDoesNotDescribeTimelinePaddingAsCapturedAudio() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 70_000, timelineDurationMs: 100_000),
                system: nil
            ),
            elapsedDurationMs: 100_000
        )
        let transcription = Transcription(
            fileName: "Recovered Review",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(MeetingPartialCapturePresentation.make(for: transcription))

        XCTAssertEqual(
            presentation.message,
            "This 1:40 session contains partial audio. Microphone captured 1:10."
        )
    }

    func testPlaybackFallbackExplainsWhyCompleteSourcesProducedPartialPlayback() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 10_000),
                system: track(durationMs: 10_000)
            ),
            elapsedDurationMs: 10_000,
            playbackFallbackSource: .system
        )
        let transcription = Transcription(
            fileName: "Fallback Review",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(MeetingPartialCapturePresentation.make(for: transcription))

        XCTAssertEqual(
            presentation.message,
            "This 0:10 session contains partial audio. Playback contains only system audio because the combined recording could not be built."
        )
    }

    func testHealthyAndLegacyMeetingsDoNotShowPartialPresentation() {
        let healthyReport = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 10_000),
                system: nil
            ),
            elapsedDurationMs: 10_000
        )

        XCTAssertNil(
            MeetingPartialCapturePresentation.make(
                for: Transcription(
                    fileName: "Healthy",
                    sourceType: .meeting,
                    meetingCaptureReport: healthyReport
                )))
        XCTAssertNil(
            MeetingPartialCapturePresentation.make(
                for: Transcription(
                    fileName: "Legacy",
                    sourceType: .meeting
                )))
    }

    private func track(
        durationMs: Int,
        timelineDurationMs: Int? = nil
    ) -> MeetingSourceAlignment.Track {
        MeetingSourceAlignment.Track(
            firstHostTime: 100,
            lastHostTime: 200,
            startOffsetMs: 0,
            writtenFrameCount: Int64(durationMs * 48),
            timelineFrameCount: timelineDurationMs.map { Int64($0 * 48) },
            sampleRate: 48_000
        )
    }
}

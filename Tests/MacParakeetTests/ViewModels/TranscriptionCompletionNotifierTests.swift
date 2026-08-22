import XCTest
@testable import MacParakeetViewModels

final class TranscriptionCompletionNotifierTests: XCTestCase {
    // MARK: - Single

    func testSingleContentNilWhenDisabled() {
        XCTAssertNil(
            TranscriptionCompletionNotifier.singleContent(
                settingEnabled: false,
                transcriptName: "lecture.mp3",
                wordCount: 100
            )
        )
    }

    func testSingleContentTitleIsTranscriptName() {
        let content = TranscriptionCompletionNotifier.singleContent(
            settingEnabled: true,
            transcriptName: "lecture.mp3",
            wordCount: 1234
        )
        XCTAssertEqual(content?.title, "lecture.mp3")
        XCTAssertEqual(content?.body, "Transcription complete \u{00B7} 1234 words")
    }

    func testSingleContentWordPluralization() {
        let one = TranscriptionCompletionNotifier.singleContent(
            settingEnabled: true,
            transcriptName: "a.wav",
            wordCount: 1
        )
        XCTAssertEqual(one?.body, "Transcription complete \u{00B7} 1 word")
    }

    // MARK: - Batch

    func testBatchContentNilWhenDisabled() {
        XCTAssertNil(
            TranscriptionCompletionNotifier.batchContent(settingEnabled: false, completed: 40, failed: 0)
        )
    }

    func testBatchContentAllSucceeded() {
        let content = TranscriptionCompletionNotifier.batchContent(
            settingEnabled: true,
            completed: 40,
            failed: 0
        )
        XCTAssertEqual(content?.title, "Transcriptions complete")
        XCTAssertEqual(content?.body, "40 files transcribed")
    }

    func testBatchContentSingleFilePluralization() {
        let content = TranscriptionCompletionNotifier.batchContent(
            settingEnabled: true,
            completed: 1,
            failed: 0
        )
        XCTAssertEqual(content?.body, "1 file transcribed")
    }

    func testBatchContentWithFailures() {
        let content = TranscriptionCompletionNotifier.batchContent(
            settingEnabled: true,
            completed: 38,
            failed: 2
        )
        XCTAssertEqual(content?.title, "Transcriptions finished with errors")
        XCTAssertEqual(content?.body, "38 transcribed \u{00B7} 2 failed")
    }

    // MARK: - Meeting ready (quiet path)

    func testMeetingReadyContentNilWhenDisabled() {
        XCTAssertNil(
            TranscriptionCompletionNotifier.meetingReadyContent(
                settingEnabled: false,
                meetingTitle: "Weekly sync",
                wordCount: 500
            )
        )
    }

    func testMeetingReadyContentTitleIsMeetingTitle() {
        let content = TranscriptionCompletionNotifier.meetingReadyContent(
            settingEnabled: true,
            meetingTitle: "Weekly sync",
            wordCount: 1432
        )
        XCTAssertEqual(content?.title, "Weekly sync")
        XCTAssertEqual(content?.body, "Meeting transcript ready \u{00B7} 1432 words")
    }

    func testMeetingReadyContentWordPluralization() {
        let one = TranscriptionCompletionNotifier.meetingReadyContent(
            settingEnabled: true,
            meetingTitle: "Standup",
            wordCount: 1
        )
        XCTAssertEqual(one?.body, "Meeting transcript ready \u{00B7} 1 word")
    }

    // MARK: - Meeting end presentation

    func testMeetingEndPresentationOpensAppWhenAutoOpenEnabled() {
        // Auto-open wins regardless of the notify setting.
        for notifyEnabled in [true, false] {
            XCTAssertEqual(
                TranscriptionCompletionNotifier.meetingEndPresentation(
                    openAppEnabled: true,
                    notifyEnabled: notifyEnabled,
                    meetingTitle: "Weekly sync",
                    wordCount: 500
                ),
                .openApp
            )
        }
    }

    func testMeetingEndPresentationQuietSignalWhenAutoOpenOffAndNotifyOn() {
        let presentation = TranscriptionCompletionNotifier.meetingEndPresentation(
            openAppEnabled: false,
            notifyEnabled: true,
            meetingTitle: "Weekly sync",
            wordCount: 1432
        )
        XCTAssertEqual(
            presentation,
            .quietSignal(
                TranscriptionCompletionNotifier.Content(
                    title: "Weekly sync",
                    body: "Meeting transcript ready \u{00B7} 1432 words"
                )
            )
        )
    }

    func testMeetingEndPresentationSilentWhenBothOff() {
        XCTAssertEqual(
            TranscriptionCompletionNotifier.meetingEndPresentation(
                openAppEnabled: false,
                notifyEnabled: false,
                meetingTitle: "Weekly sync",
                wordCount: 500
            ),
            .silent
        )
    }

    func testOnlyAutoOpenPresentationSelectsTheTranscript() {
        // Selection drives a mounted main window to Library, so anything other
        // than the auto-open path must leave the user's tab alone.
        XCTAssertTrue(TranscriptionCompletionNotifier.MeetingEndPresentation.openApp.selectsTranscription)
        XCTAssertFalse(TranscriptionCompletionNotifier.MeetingEndPresentation.silent.selectsTranscription)
        XCTAssertFalse(
            TranscriptionCompletionNotifier.MeetingEndPresentation
                .quietSignal(
                    TranscriptionCompletionNotifier.Content(title: "Weekly sync", body: "ready")
                )
                .selectsTranscription
        )
    }

    // MARK: - Meeting retry

    func testMeetingNeedsRetryContentIsIndependentFailureCopy() {
        let content = TranscriptionCompletionNotifier.meetingNeedsRetryContent()

        XCTAssertEqual(content.title, "Meeting needs a retry")
        XCTAssertEqual(content.body, "Your audio is saved.")
    }
}

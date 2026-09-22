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

    // MARK: - Batch

    func testBatchContentNilWhenDisabled() {
        XCTAssertNil(
            TranscriptionCompletionNotifier.batchContent(settingEnabled: false, completed: 40, failed: 0)
        )
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
}

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
}

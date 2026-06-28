import XCTest
@testable import MacParakeetCore

final class TranscriptSegmentClipboardTests: XCTestCase {
    func testTimestampedFormat() {
        XCTAssertEqual(
            TranscriptSegmentClipboard.text(timestampLabel: "12:03", body: "Hello world"),
            "[12:03] Hello world"
        )
    }

    func testWithoutTimestampReturnsBodyOnly() {
        XCTAssertEqual(
            TranscriptSegmentClipboard.text(
                timestampLabel: "12:03",
                body: "Hello world",
                includeTimestamp: false
            ),
            "Hello world"
        )
    }

    func testTrimsBodyAndLabel() {
        XCTAssertEqual(
            TranscriptSegmentClipboard.text(timestampLabel: " 1:00 ", body: "  hi there  "),
            "[1:00] hi there"
        )
    }

    func testEmptyLabelFallsBackToBody() {
        XCTAssertEqual(
            TranscriptSegmentClipboard.text(timestampLabel: "   ", body: "hi"),
            "hi"
        )
    }

    func testTimestampedEmptyBodyStillTrimsTrailingSpace() {
        XCTAssertEqual(
            TranscriptSegmentClipboard.text(timestampLabel: "1:00", body: "   "),
            "[1:00] "
        )
    }
}

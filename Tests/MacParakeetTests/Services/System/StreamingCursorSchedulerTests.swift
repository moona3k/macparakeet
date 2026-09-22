import XCTest
@testable import MacParakeetCore

final class StreamingCursorSchedulerTests: XCTestCase {
    func testEmptyTextIsNotStreamableAndSchedulesNothing() {
        XCTAssertFalse(StreamingCursorPolicy.isStreamable(""))
        XCTAssertTrue(StreamingCursorScheduler.schedule("").batches.isEmpty)
    }

    func testNewlineAndTabAreNotStreamable() {
        XCTAssertFalse(StreamingCursorPolicy.isStreamable("hello\nworld"))
        XCTAssertFalse(StreamingCursorPolicy.isStreamable("hello\tworld"))
        XCTAssertFalse(StreamingCursorPolicy.isStreamable("hello\rworld"))
        XCTAssertTrue(StreamingCursorPolicy.isStreamable("hello world"))
    }

    func testFamilyEmojiStaysOneGraphemeAndIsStreamable() {
        let emoji = "👨‍👩‍👧‍👦"
        XCTAssertEqual(emoji.count, 1)
        XCTAssertLessThanOrEqual(emoji.utf16.count, StreamingCursorPolicy.maxUTF16PerEvent)
        XCTAssertTrue(StreamingCursorPolicy.isStreamable(emoji))
        let schedule = StreamingCursorScheduler.schedule(emoji)
        XCTAssertEqual(schedule.batches.map(\.text), [emoji])
        XCTAssertEqual(schedule.batches.first?.delayBefore, .zero)
    }

    func testShortTextIsInstant() {
        let schedule = StreamingCursorScheduler.schedule("Hi!")
        XCTAssertEqual("Hi!".count, 3)
        XCTAssertTrue(schedule.batches.allSatisfy { $0.delayBefore == .zero })
        XCTAssertEqual(schedule.batches.map(\.text).joined(), "Hi!")
        XCTAssertTrue(schedule.batches.allSatisfy { $0.text.utf16.count <= StreamingCursorPolicy.maxUTF16PerEvent })
    }

    func testTwelveGraphemesStayWithinDurationBudgetAndLinger() {
        let text = "Hello world!"
        XCTAssertEqual(text.count, 12)
        XCTAssertTrue(StreamingCursorPolicy.isStreamable(text))
        let schedule = StreamingCursorScheduler.schedule(text)
        XCTAssertEqual(schedule.batches.map(\.text).joined(), text)
        XCTAssertEqual(schedule.batches.count, 12)
        XCTAssertTrue(schedule.batches.allSatisfy { $0.text.utf16.count <= StreamingCursorPolicy.maxUTF16PerEvent })

        let total = schedule.batches.reduce(Duration.zero) { $0 + $1.delayBefore }
        XCTAssertGreaterThanOrEqual(total, StreamingCursorPolicy.minMotionDuration)
        XCTAssertLessThanOrEqual(total, StreamingCursorPolicy.maxMotionDuration)

        let delays = schedule.batches.dropFirst().map(\.delayBefore)
        if let first = delays.first, let last = delays.last {
            XCTAssertGreaterThanOrEqual(last, first)
        }
    }

    func testLongTextIsCappedAndChunkedAtUtf16Limit() {
        let text = String(repeating: "a", count: 2000)
        let schedule = StreamingCursorScheduler.schedule(text)
        XCTAssertEqual(schedule.batches.map(\.text).joined(), text)
        XCTAssertTrue(schedule.batches.allSatisfy { $0.text.utf16.count <= StreamingCursorPolicy.maxUTF16PerEvent })
        let total = schedule.batches.reduce(Duration.zero) { $0 + $1.delayBefore }
        XCTAssertLessThanOrEqual(total, StreamingCursorPolicy.maxMotionDuration)
    }

    func testRemainingTextConcatenatesFromIndex() {
        let schedule = StreamingCursorScheduler.schedule("abcdef")
        XCTAssertEqual(schedule.remainingText(from: 0), "abcdef")
        let fromLast = schedule.remainingText(from: max(schedule.batches.count - 1, 0))
        XCTAssertTrue("abcdef".hasSuffix(fromLast))
        XCTAssertEqual(schedule.remainingText(from: schedule.batches.count), "")
    }

    func testUnknownASCIICapabilityDefaultsToPaste() {
        XCTAssertFalse(StreamingCursorPolicy.inputSourceAllowsStreaming(asciiCapable: nil))
        XCTAssertTrue(StreamingCursorPolicy.inputSourceAllowsStreaming(asciiCapable: true))
        XCTAssertFalse(StreamingCursorPolicy.inputSourceAllowsStreaming(asciiCapable: false))
    }
}

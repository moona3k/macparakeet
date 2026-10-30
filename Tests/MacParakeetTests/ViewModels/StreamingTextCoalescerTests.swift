import XCTest

@testable import MacParakeetViewModels

final class StreamingTextCoalescerTests: XCTestCase {
    func testBurstWithinIntervalPublishesOnceThenFlushesRemainder() {
        var coalescer = StreamingTextCoalescer(interval: .milliseconds(33))
        let start = ContinuousClock.now
        var published: [String] = []

        for index in 0..<1_000 {
            if let text = coalescer.append("\(index) ", at: start) {
                published.append(text)
            }
        }
        if let text = coalescer.flush() {
            published.append(text)
        }

        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published.first, "0 ")
        XCTAssertEqual(published.joined(), (0..<1_000).map { "\($0) " }.joined())
    }

    func testPublishesAgainOnlyAfterIntervalElapses() {
        var coalescer = StreamingTextCoalescer(interval: .milliseconds(33))
        let start = ContinuousClock.now

        XCTAssertEqual(coalescer.append("a", at: start), "a")
        XCTAssertNil(coalescer.append("b", at: start + .milliseconds(32)))
        XCTAssertEqual(coalescer.append("c", at: start + .milliseconds(33)), "bc")
        XCTAssertNil(coalescer.flush())
    }
}

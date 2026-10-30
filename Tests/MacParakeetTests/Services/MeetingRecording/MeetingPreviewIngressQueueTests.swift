import XCTest
@testable import MacParakeetCore

final class MeetingPreviewIngressQueueTests: XCTestCase {
    func testEnqueuePreservesOrderAndReleasesRetainedBytes() {
        var queue = MeetingPreviewIngressQueue(maxRetainedBytes: 64)
        XCTAssertTrue(queue.enqueue(batch(samples: [1, 2], source: .microphone)))
        XCTAssertTrue(queue.enqueue(batch(samples: [3], source: .system)))
        XCTAssertEqual(queue.retainedBytes, 3 * MemoryLayout<Float>.stride)
        XCTAssertEqual(queue.dequeue()?.samples, [1, 2])
        XCTAssertEqual(queue.dequeue()?.samples, [3])
        XCTAssertEqual(queue.retainedBytes, 0)
        XCTAssertNil(queue.dequeue())
        XCTAssertTrue(queue.isEmpty)
    }

    func testEnqueueRefusesBatchesThatWouldExceedTheBudget() {
        let floatBytes = MemoryLayout<Float>.stride
        var queue = MeetingPreviewIngressQueue(maxRetainedBytes: floatBytes * 4)
        XCTAssertTrue(queue.enqueue(batch(samples: [1, 2, 3, 4])))
        XCTAssertFalse(queue.enqueue(batch(samples: [5])))
        XCTAssertEqual(queue.retainedBytes, floatBytes * 4)
        XCTAssertEqual(queue.droppedBatchCount, 1)
        XCTAssertEqual(queue.droppedBytes, floatBytes)
        XCTAssertEqual(queue.dequeue()?.samples, [1, 2, 3, 4])
        XCTAssertTrue(queue.enqueue(batch(samples: [6])))
        XCTAssertEqual(queue.dequeue()?.samples, [6])
    }

    func testSingleBatchLargerThanTheBudgetIsRefused() {
        var queue = MeetingPreviewIngressQueue(maxRetainedBytes: 4)
        XCTAssertFalse(queue.enqueue(batch(samples: [1, 2])))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.retainedBytes, 0)
        XCTAssertEqual(queue.droppedBatchCount, 1)
    }

    func testEmptyBatchIsIgnored() {
        var queue = MeetingPreviewIngressQueue(maxRetainedBytes: 8)
        XCTAssertFalse(queue.enqueue(batch(samples: [])))
        XCTAssertEqual(queue.droppedBatchCount, 0)
        XCTAssertTrue(queue.isEmpty)
    }

    func testDiscardPendingDropsUnstartedPreviewAndKeepsTheBudgetAtZero() {
        var queue = MeetingPreviewIngressQueue(maxRetainedBytes: 10_000)
        XCTAssertTrue(queue.enqueue(batch(samples: [1, 2, 3])))
        XCTAssertTrue(queue.enqueue(batch(samples: [4])))
        queue.discardPending()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.retainedBytes, 0)
        XCTAssertEqual(queue.droppedBatchCount, 2)
        XCTAssertNil(queue.dequeue())
        XCTAssertTrue(queue.enqueue(batch(samples: [9])))
        XCTAssertEqual(queue.dequeue()?.samples, [9])
    }

    func testManySmallBatchesStayWithinTheBudget() {
        let floatBytes = MemoryLayout<Float>.stride
        var queue = MeetingPreviewIngressQueue(maxRetainedBytes: floatBytes * 8)
        var admitted = 0
        for index in 0..<20 {
            if queue.enqueue(batch(samples: [Float(index)])) {
                admitted += 1
            }
            XCTAssertLessThanOrEqual(queue.retainedBytes, floatBytes * 8)
        }
        XCTAssertEqual(admitted, 8)
        XCTAssertEqual(queue.droppedBatchCount, 12)
        var values: [Float] = []
        while let batch = queue.dequeue() {
            values.append(contentsOf: batch.samples)
            XCTAssertLessThanOrEqual(queue.retainedBytes, floatBytes * 8)
        }
        XCTAssertEqual(values, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    private func batch(
        samples: [Float],
        source: AudioSource = .microphone
    ) -> MeetingPreviewIngressQueue.Batch {
        MeetingPreviewIngressQueue.Batch(
            source: source,
            samples: samples,
            hostTime: nil,
            bufferRms: 0
        )
    }
}

import AVFoundation
import os
import XCTest
@testable import MacParakeetCore

final class MutableMicrophoneTapHandlerTests: XCTestCase {
    func testReplaceRoutesFutureBuffersToTheNewHandler() throws {
        let (buffer, time) = try makeBufferAndTime()
        let initialCount = OSAllocatedUnfairLock(initialState: 0)
        let replacementCount = OSAllocatedUnfairLock(initialState: 0)
        let handler = MutableMicrophoneTapHandler { _, _ in
            initialCount.withLock { $0 += 1 }
        }

        handler.invoke(buffer: buffer, time: time)
        handler.replace { _, _ in
            replacementCount.withLock { $0 += 1 }
        }
        handler.invoke(buffer: buffer, time: time)

        XCTAssertEqual(initialCount.withLock { $0 }, 1)
        XCTAssertEqual(replacementCount.withLock { $0 }, 1)
    }

    func testClearStopsFutureBufferDelivery() throws {
        let (buffer, time) = try makeBufferAndTime()
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let handler = MutableMicrophoneTapHandler { _, _ in
            invocationCount.withLock { $0 += 1 }
        }

        handler.clear()
        handler.invoke(buffer: buffer, time: time)

        XCTAssertEqual(invocationCount.withLock { $0 }, 0)
    }

    func testClearAfterSustainedDeliveryDoesNotOverflowTheStack() throws {
        let (buffer, time) = try makeBufferAndTime()
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let handler = MutableMicrophoneTapHandler { _, _ in
            invocationCount.withLock { $0 += 1 }
        }

        for _ in 0..<50_000 {
            handler.invoke(buffer: buffer, time: time)
        }

        XCTAssertEqual(invocationCount.withLock { $0 }, 50_000)
        handler.clear()
    }

    func testCallbackMonitoringRequiresAFirstCallbackAndClearInvalidatesIt() throws {
        let (buffer, time) = try makeBufferAndTime()
        let handler = MutableMicrophoneTapHandler { _, _ in }
        let timeout: TimeInterval = 5

        handler.activateCallbackMonitoring()
        XCTAssertNil(
            handler.stalledCallbackGap(
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                timeout: timeout
            ),
            "startup without a first callback belongs to the existing first-buffer watchdog"
        )

        handler.invoke(buffer: buffer, time: time)
        let afterCallback = DispatchTime.now().uptimeNanoseconds
        XCTAssertNil(
            handler.stalledCallbackGap(
                nowUptimeNanoseconds: afterCallback,
                timeout: timeout
            )
        )
        XCTAssertNotNil(
            handler.stalledCallbackGap(
                nowUptimeNanoseconds: afterCallback + 6_000_000_000,
                timeout: timeout
            )
        )

        handler.clear()
        XCTAssertNil(
            handler.stalledCallbackGap(
                nowUptimeNanoseconds: afterCallback + 6_000_000_000,
                timeout: timeout
            )
        )
    }

    private func makeBufferAndTime() throws -> (AVAudioPCMBuffer, AVAudioTime) {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
        )
        let time = AVAudioTime(sampleTime: 0, atRate: format.sampleRate)
        return (buffer, time)
    }
}

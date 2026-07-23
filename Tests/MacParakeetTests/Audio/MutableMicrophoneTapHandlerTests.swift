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
            handler.livenessFailure(
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                callbackStallTimeout: timeout,
                zeroFilledTimeout: 0
            ),
            "startup without a first callback belongs to the existing first-buffer watchdog"
        )

        handler.invoke(buffer: buffer, time: time)
        let afterCallback = DispatchTime.now().uptimeNanoseconds
        XCTAssertNil(
            handler.livenessFailure(
                nowUptimeNanoseconds: afterCallback,
                callbackStallTimeout: timeout,
                zeroFilledTimeout: 0
            )
        )
        XCTAssertNotNil(
            handler.livenessFailure(
                nowUptimeNanoseconds: afterCallback + 6_000_000_000,
                callbackStallTimeout: timeout,
                zeroFilledTimeout: 0
            )
        )

        handler.clear()
        XCTAssertNil(
            handler.livenessFailure(
                nowUptimeNanoseconds: afterCallback + 6_000_000_000,
                callbackStallTimeout: timeout,
                zeroFilledTimeout: 0
            )
        )
    }

    func testKnownBluetoothDropsExactZeroButForwardsAnyRealSample() throws {
        let (buffer, time) = try makeBufferAndTime()
        buffer.frameLength = 4
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let handler = MutableMicrophoneTapHandler(requiresNonZeroSignal: true) { _, _ in
            invocationCount.withLock { $0 += 1 }
        }
        handler.activateCallbackMonitoring()

        handler.invoke(buffer: buffer, time: time)
        XCTAssertEqual(invocationCount.withLock { $0 }, 0)

        buffer.floatChannelData?[0][0] = .leastNonzeroMagnitude
        handler.invoke(buffer: buffer, time: time)
        XCTAssertEqual(
            invocationCount.withLock { $0 },
            1,
            "The Bluetooth guard is exact-zero detection, not a voice-activity threshold"
        )
    }

    func testVPIOSignalDetectionUsesOnlyMicrophoneChannelZero() throws {
        let (buffer, time) = try makeBufferAndTime(channels: 2)
        buffer.frameLength = 4
        buffer.floatChannelData?[1][0] = .leastNonzeroMagnitude
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let handler = MutableMicrophoneTapHandler(
            requiresNonZeroSignal: true,
            checksOnlyChannelZeroForSignal: true
        ) { _, _ in
            invocationCount.withLock { $0 += 1 }
        }
        handler.activateCallbackMonitoring()

        handler.invoke(buffer: buffer, time: time)
        XCTAssertEqual(
            invocationCount.withLock { $0 },
            0,
            "VPIO reference-channel signal must not certify a silent microphone channel"
        )

        buffer.floatChannelData?[0][0] = .leastNonzeroMagnitude
        handler.invoke(buffer: buffer, time: time)
        XCTAssertEqual(invocationCount.withLock { $0 }, 1)
    }

    func testRawMultichannelSignalDetectionChecksEveryInputChannel() throws {
        let (buffer, time) = try makeBufferAndTime(channels: 2)
        buffer.frameLength = 4
        buffer.floatChannelData?[1][0] = .leastNonzeroMagnitude
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let handler = MutableMicrophoneTapHandler(requiresNonZeroSignal: true) { _, _ in
            invocationCount.withLock { $0 += 1 }
        }
        handler.activateCallbackMonitoring()

        handler.invoke(buffer: buffer, time: time)

        XCTAssertEqual(invocationCount.withLock { $0 }, 1)
    }

    private func makeBufferAndTime(
        channels: AVAudioChannelCount = 1
    ) throws -> (AVAudioPCMBuffer, AVAudioTime) {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
        )
        let time = AVAudioTime(sampleTime: 0, atRate: format.sampleRate)
        return (buffer, time)
    }
}

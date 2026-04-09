import AVFoundation
import XCTest
@testable import MacParakeetCore

final class AudioRecorderFormatChangeTests: XCTestCase {
    func testTapConverterNeedsRebuildWhenNoCachedFormat() throws {
        let incoming = try makeFormat()
        XCTAssertTrue(tapConverterNeedsRebuild(cachedSourceFormat: nil, incomingBufferFormat: incoming))
    }

    func testTapConverterDoesNotNeedRebuildForEquivalentFormat() throws {
        let cached = try makeFormat()
        let incoming = try makeFormat()
        XCTAssertFalse(
            tapConverterNeedsRebuild(cachedSourceFormat: cached, incomingBufferFormat: incoming)
        )
    }

    func testTapConverterNeedsRebuildWhenInterleavingChanges() throws {
        let nonInterleaved = try makeFormat(interleaved: false)
        let interleaved = try makeFormat(interleaved: true)
        XCTAssertTrue(
            tapConverterNeedsRebuild(
                cachedSourceFormat: nonInterleaved,
                incomingBufferFormat: interleaved
            )
        )
    }

    func testTapConverterNeedsRebuildWhenSampleRateChanges() throws {
        let cached = try makeFormat(sampleRate: 48_000)
        let incoming = try makeFormat(sampleRate: 44_100)
        XCTAssertTrue(
            tapConverterNeedsRebuild(cachedSourceFormat: cached, incomingBufferFormat: incoming)
        )
    }

    private func makeFormat(
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 2,
        interleaved: Bool = false
    ) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            )
        )
    }
}

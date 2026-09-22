import AVFoundation
import XCTest
@testable import MacParakeetCore

/// Unit coverage for `extractChannelZero(from:)` — the design rule that makes
/// dictation correct under VPIO. ch[0] of a VPIO duplex layout is the
/// post-AEC processed mono; mixing channels would dilute the AEC.
final class ExtractChannelZeroTests: XCTestCase {
    func testMonoBufferReturnedUnchanged() throws {
        let buffer = try makeNonInterleavedFloatBuffer(channels: 1, frames: 64) { ch, frame in
            Float(frame) * 0.01
        }
        let result = try XCTUnwrap(extractChannelZero(from: buffer))
        XCTAssertTrue(result === buffer, "Mono input should be returned as-is, no copy")
    }

    func testMultiChannelNonInterleavedFloat32CopiesChannelZero() throws {
        // Note: AVAudioFormat's convenience init only accepts standard
        // channel counts (1/2/4/6/8). Production VPIO produces ch=9 via
        // an explicit AudioChannelLayout — for unit purposes ch=4 with
        // distinguishable per-channel values is sufficient to prove the
        // copy semantics.
        let buffer = try makeNonInterleavedFloatBuffer(channels: 4, frames: 128) { ch, frame in
            // Channel 0 holds the "voice" we want; other channels hold
            // distinguishable values so we can prove they were dropped.
            ch == 0 ? Float(frame) * 0.5 : Float(ch) * 100 + Float(frame)
        }

        let result = try XCTUnwrap(extractChannelZero(from: buffer))
        XCTAssertFalse(result === buffer, "Multi-channel input must be copied, not returned in place")
        XCTAssertEqual(result.format.channelCount, 1)
        XCTAssertEqual(result.format.sampleRate, buffer.format.sampleRate)
        XCTAssertFalse(result.format.isInterleaved)
        XCTAssertEqual(result.frameLength, buffer.frameLength)

        let dst = try XCTUnwrap(result.floatChannelData)
        let src = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            XCTAssertEqual(dst[0][frame], src[0][frame], accuracy: 0.0001, "Frame \(frame) must match ch[0]")
        }
    }

    func testMultiChannelNonInterleavedInt16CopiesChannelZero() throws {
        // Build an Int16 non-interleaved 4-channel format via explicit
        // ASBD + discrete-in-order channel layout (the convenience
        // initializer doesn't cover this combination).
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 4,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder) | 4
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd, channelLayout: layout))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        let data = try XCTUnwrap(buffer.int16ChannelData)
        for frame in 0..<64 {
            data[0][frame] = Int16(frame) * 10
            data[1][frame] = Int16(frame) * -10
            data[2][frame] = 32_000
            data[3][frame] = -32_000
        }

        let result = try XCTUnwrap(extractChannelZero(from: buffer))
        XCTAssertEqual(result.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(result.format.channelCount, 1)
        let dst = try XCTUnwrap(result.int16ChannelData)
        for frame in 0..<64 {
            XCTAssertEqual(dst[0][frame], Int16(frame) * 10)
        }
    }

    func testInterleavedMultiChannelReturnedUnchanged() throws {
        // We don't currently extract from interleaved layouts (VPIO and
        // most macOS device formats are non-interleaved). Pass-through is
        // the safe degradation — the converter mixes channels, which is
        // wrong for VPIO but defensible for arbitrary multi-mic devices.
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: true
            ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32

        let result = try XCTUnwrap(extractChannelZero(from: buffer))
        XCTAssertTrue(result === buffer, "Interleaved multi-channel input is passed through unchanged")
    }

    func testRawMicrophoneMultiChannelDownmixesAllChannels() throws {
        let buffer = try makeNonInterleavedFloatBuffer(channels: 4, frames: 16) { channel, frame in
            channel == 1 ? Float(frame) + 0.5 : 0
        }

        let result = try XCTUnwrap(
            microphoneCaptureMonoBuffer(from: buffer, extractVPIOChannelZero: false)
        )
        XCTAssertFalse(result === buffer)
        XCTAssertEqual(result.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(result.format.channelCount, 1)
        XCTAssertEqual(result.format.sampleRate, buffer.format.sampleRate)

        let dst = try XCTUnwrap(result.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            XCTAssertEqual(dst[0][frame], (Float(frame) + 0.5) / 4, accuracy: 0.0001)
        }
    }

    func testRawDownmixExactInverseUsesLowestIndexEnergyTieAcrossPCMLayouts() throws {
        let left: [Float] = [0.25, -0.5, 0.75, -0.125]
        try assertRawStereoDownmix(left: left, right: left.map { -$0 }, expected: left)
    }

    func testRawDownmixNearInverseSelectsOneDominantChannelForWholeBuffer() throws {
        // The right channel wins the first frame, but the left wins total energy.
        let dominant: [Float] = [0.25, 0.5, -0.75, 0.125]
        let other: [Float] = [-0.375, -0.45, 0.70, -0.12]
        try assertRawStereoDownmix(left: dominant, right: other, expected: dominant)
        try assertRawStereoDownmix(left: other, right: dominant, expected: dominant)
    }

    func testRawDownmixPreservesOrdinaryIndependentAndDisjointChannelMeans() throws {
        try assertRawStereoDownmix(
            left: [0.25, 0, 0.5, -0.25, 0],
            right: [0.5, -0.5, 0, 0.125, 0],
            expected: [0.375, -0.25, 0.25, -0.0625, 0]
        )
        try assertRawStereoDownmix(left: [0, 0], right: [0, 0], expected: [0, 0])
    }

    private func assertRawStereoDownmix(
        left: [Float],
        right: [Float],
        expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for commonFormat in [
            AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32,
        ] {
            for interleaved in [false, true] {
                let format = try XCTUnwrap(
                    AVAudioFormat(
                        commonFormat: commonFormat, sampleRate: 48_000,
                        channels: 2, interleaved: interleaved
                    )
                )
                let buffer = try XCTUnwrap(
                    AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))
                )
                buffer.frameLength = buffer.frameCapacity
                for channel in 0..<2 {
                    for frame in left.indices {
                        let value = channel == 0 ? left[frame] : right[frame]
                        let dataChannel = interleaved ? 0 : channel
                        let offset = interleaved ? frame * 2 + channel : frame
                        switch commonFormat {
                        case .pcmFormatFloat32:
                            try XCTUnwrap(buffer.floatChannelData)[dataChannel][offset] = value
                        case .pcmFormatInt16:
                            try XCTUnwrap(buffer.int16ChannelData)[dataChannel][offset] =
                                Int16(value * Float(Int16.max))
                        case .pcmFormatInt32:
                            try XCTUnwrap(buffer.int32ChannelData)[dataChannel][offset] =
                                Int32(value * Float(Int32.max))
                        default:
                            XCTFail("Unsupported test PCM format", file: file, line: line)
                        }
                    }
                }
                let mono = try XCTUnwrap(
                    microphoneCaptureMonoBuffer(from: buffer, extractVPIOChannelZero: false)
                )
                let samples = try XCTUnwrap(mono.floatChannelData)[0]
                for frame in expected.indices {
                    XCTAssertEqual(
                        samples[frame], expected[frame], accuracy: 0.0001,
                        "format=\(commonFormat) interleaved=\(interleaved) frame=\(frame)",
                        file: file, line: line
                    )
                }
            }
        }
    }

    func testVPIOMicrophoneMultiChannelStillUsesChannelZeroOnly() throws {
        let buffer = try makeNonInterleavedFloatBuffer(channels: 4, frames: 16) { channel, frame in
            channel == 0 ? Float(frame) + 0.25 : 10_000
        }

        let result = try XCTUnwrap(
            microphoneCaptureMonoBuffer(from: buffer, extractVPIOChannelZero: true)
        )
        XCTAssertEqual(result.format.channelCount, 1)

        let dst = try XCTUnwrap(result.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            XCTAssertEqual(dst[0][frame], Float(frame) + 0.25, accuracy: 0.0001)
        }
    }

    func testZeroFrameBufferRoundTrips() throws {
        let buffer = try makeNonInterleavedFloatBuffer(channels: 4, frames: 64) { _, _ in 0 }
        buffer.frameLength = 0

        let result = try XCTUnwrap(extractChannelZero(from: buffer))
        XCTAssertEqual(result.frameLength, 0)
        XCTAssertEqual(result.format.channelCount, 1)
    }

    private func makeNonInterleavedFloatBuffer(
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        sampleRate: Double = 48_000,
        fill: (_ channel: Int, _ frame: Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let format: AVAudioFormat
        if channels <= 2 {
            format = try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: channels,
                    interleaved: false
                ))
        } else {
            // AVAudioFormat's convenience initializer only accepts standard
            // mono/stereo layouts. For ch≥3 we use the discrete-in-order
            // channel layout — N unrelated channels — which matches how
            // VPIO advertises its multi-channel duplex output.
            let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder) | channels
            let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
            format = try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    interleaved: false,
                    channelLayout: layout
                ))
        }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for ch in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[ch][frame] = fill(ch, frame)
            }
        }
        return buffer
    }
}

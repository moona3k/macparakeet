import AVFoundation
import XCTest
@testable import MacParakeetCore

final class MeetingDecodedAudioTests: XCTestCase {
    func testScratchIsUnlinkedWhileOpenAndSupportsRangeReadsAndAppendAfterRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var released: MeetingDecodedAudio?
        do {
            let audio = try MeetingDecodedAudio(temporaryDirectory: directory)
            released = audio
            let first: [Float] = [0, 0.25, -1, .greatestFiniteMagnitude]
            try first.withUnsafeBufferPointer { try audio.append($0) }
            XCTAssertEqual(try audio.read(1..<3), [0.25, -1])
            try [Float(7), 8].withUnsafeBufferPointer { try audio.append($0) }
            XCTAssertEqual(audio.count, 6)
            XCTAssertEqual(try audio.read(0..<6), first + [7, 8])
            XCTAssertEqual(try audio.read(6..<6), [])
            XCTAssertThrowsError(try audio.read(-1..<1))
            XCTAssertThrowsError(try audio.read(5..<7))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
        XCTAssertNil(released)
    }

    func testScratchCreationFailureThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("missing")
        XCTAssertThrowsError(try MeetingDecodedAudio(temporaryDirectory: missing))
    }

    func testScratchDecodeMatchesSequentialArrayDecodeAndEnforcesFrameLimit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        // Exercise channel mixing, resampling, multiple codec buffers and a tail.
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 49_777))
            buffer.frameLength = buffer.frameCapacity
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                channels[0][i] = Float(sin(Double(i) * 0.17)) * 0.2
                channels[1][i] = Float(cos(Double(i) * 0.09)) * 0.1
            }
            try file.write(from: buffer)
        }
        let expected = try await MeetingCleanedMicRenderer.decodeMonoFloat(url: url, sampleRate: 16_000)
        let audio = try await MeetingCleanedMicRenderer.decodeToScratch(
            url: url, sampleRate: 16_000, maxFrames: 100_000)
        XCTAssertEqual(audio.count, expected.count)
        XCTAssertEqual(try audio.read(0..<audio.count), expected)
        XCTAssertGreaterThan(audio.count, 16_000)
        do {
            _ = try await MeetingCleanedMicRenderer.decodeToScratch(url: url, sampleRate: 16_000, maxFrames: 100)
            XCTFail("expected decoded frame limit")
        } catch MeetingCleanedMicRenderer.DecodeLimitExceeded.tooManyFrames(let count, let maximum) {
            XCTAssertGreaterThan(count, maximum)
            XCTAssertEqual(maximum, 100)
        }
    }

    func testDiskAndArrayProbeAgreeAcrossOffsetsAndReferenceEnergy() throws {
        let far = MeetingAecSignal.voiceLike(
            sampleCount: 16_000 * 12, sampleRate: 16_000,
            formants: MeetingAecScenarioFactory.farFormants, seed: 12)
        let mic = MeetingAecEchoPath(taps: [(delay: 120, gain: 0.6)]).apply(to: far)
        for system in [far, [Float](repeating: 0, count: far.count)] {
            let micFile = try scratch(mic)
            let systemFile = try scratch(system)
            for offset in [-500, 0, 500] {
                let expected = try MeetingCleanedMicRenderer.probeEchoPath(
                    microphone: mic, system: system, microphoneStartOffsetMs: 0,
                    systemStartOffsetMs: offset, sampleRate: 16_000)
                let actual = try MeetingCleanedMicRenderer.probeEchoPath(
                    microphone: MeetingAudioSamples(micFile), system: MeetingAudioSamples(systemFile),
                    microphoneStartOffsetMs: 0, systemStartOffsetMs: offset, sampleRate: 16_000)
                XCTAssertEqual(actual, expected)
            }
        }
    }

    func testConditioningMatchesPriorAlgorithmIncludingFlushAndMissingReference() throws {
        let mic = (0..<12_777).map { Float(sin(Double($0) * 0.03)) * 0.2 }
        let system = (0..<9_001).map { Float(cos(Double($0) * 0.07)) * 0.1 }
        let micFile = try scratch(mic)
        let systemFile = try scratch(system)
        for offset in [-500, 0, 500, 10_000] {
            for mode in [TailConditioner.Mode.normal, .underflush, .overflush] {
                let expected = priorConditioning(
                    mic: mic, system: system, offsetMs: offset, conditioner: TailConditioner(mode: mode))
                let stream = MeetingCleanedMicRenderer.ConditionedStream(
                    microphone: MeetingAudioSamples(micFile), system: MeetingAudioSamples(systemFile),
                    microphoneStartOffsetMs: 0, systemStartOffsetMs: offset,
                    sampleRate: 16_000, conditioner: TailConditioner(mode: mode))
                var actual: [Float] = []
                while let chunk = try stream.next() { actual += chunk }
                XCTAssertEqual(actual, expected, "offset=\(offset) mode=\(mode)")
                XCTAssertEqual(actual.count, mic.count)
                let inputPower = mic.reduce(0.0) { $0 + Double($1) * Double($1) }
                let outputPower = actual.reduce(0.0) { $0 + Double($1) * Double($1) }
                XCTAssertEqual(stream.rmsRatio, Float((outputPower / inputPower).squareRoot()))
            }
        }
    }

    func testLongStreamAndProbeRequestOnlyBoundedRanges() throws {
        let count = 16_000 * 600 + 17
        var maximumRead = 0
        let source = MeetingAudioSamples(count: count) { range in
            maximumRead = max(maximumRead, range.count)
            return [Float](repeating: 0.1, count: range.count)
        }
        let stream = MeetingCleanedMicRenderer.ConditionedStream(
            microphone: source, system: source, microphoneStartOffsetMs: 0,
            systemStartOffsetMs: 500, sampleRate: 16_000, conditioner: PassthroughMicConditioner())
        var emitted = 0
        while let chunk = try stream.next() {
            XCTAssertLessThanOrEqual(chunk.count, 4_096)
            emitted += chunk.count
        }
        XCTAssertEqual(emitted, count)
        XCTAssertLessThanOrEqual(maximumRead, 4_096)
        XCTAssertEqual(stream.rmsRatio, 1)
        maximumRead = 0
        _ = try MeetingCleanedMicRenderer.probeEchoPath(
            microphone: source, system: source, microphoneStartOffsetMs: 0,
            systemStartOffsetMs: 500, sampleRate: 16_000)
        XCTAssertGreaterThan(maximumRead, 0)
        XCTAssertLessThanOrEqual(maximumRead, 16_000 * 10)
    }

    func testReadFailureAndCancellationPropagateFromStream() async throws {
        enum ReadFailure: Error { case failed }
        let source = MeetingAudioSamples(count: 5_000) { _ in throw ReadFailure.failed }
        let stream = MeetingCleanedMicRenderer.ConditionedStream(
            microphone: source, system: source, microphoneStartOffsetMs: 0,
            systemStartOffsetMs: 0, sampleRate: 16_000, conditioner: PassthroughMicConditioner())
        XCTAssertThrowsError(try stream.next()) { XCTAssertTrue($0 is ReadFailure) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let samples = MeetingAudioSamples([Float](repeating: 1, count: 10))
            let cancelled = MeetingCleanedMicRenderer.ConditionedStream(
                microphone: samples, system: samples, microphoneStartOffsetMs: 0,
                systemStartOffsetMs: 0, sampleRate: 16_000, conditioner: PassthroughMicConditioner())
            return try cancelled.next()
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    private func scratch(_ samples: [Float]) throws -> MeetingDecodedAudio {
        let audio = try MeetingDecodedAudio()
        try samples.withUnsafeBufferPointer { try audio.append($0) }
        return audio
    }

    // Frozen pre-streaming algorithm, used only on small deterministic fixtures
    // to catch alignment/cadence/tail changes independently of the pull stream.
    private func priorConditioning(
        mic: [Float], system: [Float], offsetMs: Int, conditioner: any MicConditioning
    ) -> [Float] {
        conditioner.reset()
        // The renderer reads the reference 20 ms early (#920 lookahead).
        let shift = Int((Double(offsetMs - 20) / 1_000 * 16_000).rounded())
        var output: [Float] = []
        var cursor = 0
        while cursor < mic.count {
            let end = min(cursor + 4_096, mic.count)
            let reference = (cursor..<end).map { i -> Float in
                let index = i - shift
                return index >= 0 && index < system.count ? system[index] : 0
            }
            output += conditioner.condition(
                microphone: Array(mic[cursor..<end]), speaker: reference, hasSpeakerReference: true)
            cursor = end
        }
        output += conditioner.flush()
        if output.count > mic.count { output.removeLast(output.count - mic.count) }
        if output.count < mic.count { output.append(contentsOf: mic[output.count...]) }
        return output
    }
}

private final class TailConditioner: MicConditioning, @unchecked Sendable {
    enum Mode { case normal, underflush, overflush }
    let mode: Mode
    private var tail: [Float] = []
    var diagnostics: MeetingEchoSuppressionDiagnostics { .passthrough() }
    init(mode: Mode) { self.mode = mode }
    func reset() { tail = [] }
    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        let values = zip(microphone, speaker).map { $0 - $1 * 0.5 }
        let combined = tail + values
        let held = min(127, combined.count)
        tail = Array(combined.suffix(held))
        return Array(combined.dropLast(held))
    }
    func flush() -> [Float] {
        switch mode {
        case .normal: return tail
        case .underflush: return []
        case .overflush: return tail + [Float](repeating: 7, count: 199)
        }
    }
}

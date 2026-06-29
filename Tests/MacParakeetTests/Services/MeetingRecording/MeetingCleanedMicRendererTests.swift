import AVFoundation
import XCTest
@testable import MacParakeetCore

/// Unit coverage for the post-stop cleaned-mic renderer (plan #605 U3). The DSP
/// core (`alignAndCondition`) is exercised with the measurement-harness
/// conditioners so echo cancellation and start-offset alignment are checked on
/// ground-truth fixtures; the I/O path is round-tripped through real AAC `.m4a`
/// files (lossy, so only structure/duration is asserted).
final class MeetingCleanedMicRendererTests: XCTestCase {
    private let echoPath = MeetingAecEchoPath(taps: [(delay: 120, gain: 0.6)])

    // MARK: DSP core

    func testAlignAndConditionOutputMatchesMicrophoneLength() {
        let mic = [Float](repeating: 0.1, count: 5_000)
        let system = [Float](repeating: 0.2, count: 3_000)
        for (micOff, sysOff) in [(0, 0), (0, 500), (500, 0)] {
            let result = MeetingCleanedMicRenderer.alignAndCondition(
                microphone: mic, system: system,
                microphoneStartOffsetMs: micOff, systemStartOffsetMs: sysOff,
                sampleRate: 16_000,
                conditioner: PassthroughMicConditioner())
            XCTAssertEqual(result.output.count, mic.count,
                "cleaned output must align 1:1 with the raw mic (offsets \(micOff)/\(sysOff))")
        }
    }

    func testAlignAndConditionCancelsEchoWhenAligned() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: echoPath, noiseLevel: 0.0001)
        let suppressor = StreamingMeetingEchoSuppressor(
            processor: MeetingAecNLMSProcessor(), referenceDelaySamples: 120)
        let result = MeetingCleanedMicRenderer.alignAndCondition(
            microphone: scenario.mic, system: scenario.farEnd,
            microphoneStartOffsetMs: 0, systemStartOffsetMs: 0,
            sampleRate: 16_000, conditioner: suppressor)

        let erle = MeetingAecMetrics.erleDB(
            mic: scenario.mic, output: result.output, over: scenario.steadyStateWindow)
        XCTAssertGreaterThan(erle, 8, "an aligned reference cancels the synthetic echo (ERLE \(erle) dB)")
        XCTAssertGreaterThan(result.processedFrames, 0)
        XCTAssertEqual(result.processingFailures, 0)
        // The frame-carrying suppressor (unlike passthrough) can hold a partial
        // final frame; the renderer clamps the flushed tail so the cleaned output
        // still aligns 1:1 with the raw mic.
        XCTAssertEqual(result.output.count, scenario.mic.count,
            "cleaned output stays aligned 1:1 with the raw mic after flush")
    }

    func testAlignAndConditionAppliesRecordedStartOffset() {
        // The system stream started 500 ms (8000 samples at 16 kHz) after the
        // mic, so the mic's echo only begins 8000 samples in. Only applying the
        // recorded offset realigns the reference; ignoring it leaves the echo
        // 8000 samples out of phase, far beyond the NLMS filter's reach.
        let leadSamples = 8_000
        let leadMs = 500
        let far = MeetingAecSignal.voiceLike(
            sampleCount: 24_000, sampleRate: 16_000,
            formants: MeetingAecScenarioFactory.farFormants, seed: 0x0B0B)
        let echoFull = echoPath.apply(to: far)
        let mic = [Float](repeating: 0, count: leadSamples) + echoFull
        let window = (mic.count / 2)..<(mic.count - 256)

        func erle(systemOffsetMs: Int) -> Double {
            let suppressor = StreamingMeetingEchoSuppressor(
                processor: MeetingAecNLMSProcessor(), referenceDelaySamples: 120)
            let out = MeetingCleanedMicRenderer.alignAndCondition(
                microphone: mic, system: far,
                microphoneStartOffsetMs: 0, systemStartOffsetMs: systemOffsetMs,
                sampleRate: 16_000, conditioner: suppressor)
            return MeetingAecMetrics.erleDB(mic: mic, output: out.output, over: window)
        }

        let aligned = erle(systemOffsetMs: leadMs)
        let misaligned = erle(systemOffsetMs: 0)
        XCTAssertGreaterThan(aligned, misaligned + 6,
            "the recorded start offset realigns the reference and restores cancellation "
            + "(aligned \(aligned) dB vs ignoring-offset \(misaligned) dB)")
    }

    // MARK: I/O round-trip

    func testRenderProducesDecodableCleanedFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scenario = MeetingAecScenarioFactory.make(
            name: "double-talk", nearEndActive: true, farEndActive: true, echoPath: echoPath)
        let micURL = dir.appendingPathComponent("microphone.m4a")
        let sysURL = dir.appendingPathComponent("system.m4a")
        try await MeetingCleanedMicRenderer.encodeMonoFloat(
            scenario.mic, sampleRate: 16_000, to: micURL, fileManager: .default)
        try await MeetingCleanedMicRenderer.encodeMonoFloat(
            scenario.farEnd, sampleRate: 16_000, to: sysURL, fileManager: .default)

        let outURL = dir.appendingPathComponent(MeetingCleanedMicRenderer.cleanedMicrophoneFileName)
        let outcome = try await MeetingCleanedMicRenderer().render(
            microphoneURL: micURL, systemURL: sysURL,
            sourceAlignment: equalAlignment(),
            outputURL: outURL,
            conditioner: StreamingMeetingEchoSuppressor(
                processor: MeetingAecNLMSProcessor(), referenceDelaySamples: 120))

        guard case .rendered(let result) = outcome else {
            return XCTFail("expected .rendered, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        XCTAssertGreaterThan(result.processedFrames, 0)
        XCTAssertEqual(result.processingFailures, 0)

        let decoded = try await MeetingCleanedMicRenderer.decodeMonoFloat(
            url: outURL, sampleRate: 16_000)
        let expected = Double(scenario.mic.count) / 16_000.0
        let actual = Double(decoded.count) / 16_000.0
        XCTAssertEqual(actual, expected, accuracy: 0.3, "cleaned duration ~ raw mic duration")
    }

    func testRenderSkipsWhenConditionerIsPassthrough() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (micURL, sysURL) = try await writeSourcePair(in: dir)

        let outcome = try await MeetingCleanedMicRenderer().render(
            microphoneURL: micURL, systemURL: sysURL,
            sourceAlignment: equalAlignment(),
            outputURL: dir.appendingPathComponent(MeetingCleanedMicRenderer.cleanedMicrophoneFileName),
            conditioner: PassthroughMicConditioner())

        XCTAssertEqual(outcome, .skipped(.conditionerUnavailable))
    }

    func testRenderSkipsWhenSystemReferenceMissing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (micURL, _) = try await writeSourcePair(in: dir, includeSystem: false)

        let outcome = try await MeetingCleanedMicRenderer().render(
            microphoneURL: micURL,
            systemURL: dir.appendingPathComponent("system.m4a"),
            sourceAlignment: equalAlignment(),
            outputURL: dir.appendingPathComponent(MeetingCleanedMicRenderer.cleanedMicrophoneFileName),
            conditioner: StreamingMeetingEchoSuppressor(
                processor: MeetingAecNLMSProcessor(), referenceDelaySamples: 120))

        XCTAssertEqual(outcome, .skipped(.missingSystemReference))
    }

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func equalAlignment() -> MeetingSourceAlignment {
        MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil)
    }

    @discardableResult
    private func writeSourcePair(in dir: URL, includeSystem: Bool = true) async throws -> (URL, URL) {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: true, farEndActive: true, echoPath: echoPath)
        let micURL = dir.appendingPathComponent("microphone.m4a")
        let sysURL = dir.appendingPathComponent("system.m4a")
        try await MeetingCleanedMicRenderer.encodeMonoFloat(
            scenario.mic, sampleRate: 16_000, to: micURL, fileManager: .default)
        if includeSystem {
            try await MeetingCleanedMicRenderer.encodeMonoFloat(
                scenario.farEnd, sampleRate: 16_000, to: sysURL, fileManager: .default)
        }
        return (micURL, sysURL)
    }
}

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

    func testAlignAndConditionOutputMatchesMicrophoneLength() throws {
        let mic = [Float](repeating: 0.1, count: 5_000)
        let system = [Float](repeating: 0.2, count: 3_000)
        for (micOff, sysOff) in [(0, 0), (0, 500), (500, 0)] {
            let result = try MeetingCleanedMicRenderer.alignAndCondition(
                microphone: mic, system: system,
                microphoneStartOffsetMs: micOff, systemStartOffsetMs: sysOff,
                sampleRate: 16_000,
                conditioner: PassthroughMicConditioner())
            XCTAssertEqual(
                result.output.count, mic.count,
                "cleaned output must align 1:1 with the raw mic (offsets \(micOff)/\(sysOff))")
        }
    }

    func testAlignAndConditionCancelsEchoWhenAligned() throws {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: echoPath, noiseLevel: 0.0001)
        let suppressor = StreamingMeetingEchoSuppressor(
            processor: MeetingAecNLMSProcessor(), referenceDelaySamples: 120)
        let result = try MeetingCleanedMicRenderer.alignAndCondition(
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
        XCTAssertEqual(
            result.output.count, scenario.mic.count,
            "cleaned output stays aligned 1:1 with the raw mic after flush")
    }

    func testAlignAndConditionAppliesRecordedStartOffset() throws {
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

        func erle(systemOffsetMs: Int) throws -> Double {
            let suppressor = StreamingMeetingEchoSuppressor(
                processor: MeetingAecNLMSProcessor(), referenceDelaySamples: 120)
            let out = try MeetingCleanedMicRenderer.alignAndCondition(
                microphone: mic, system: far,
                microphoneStartOffsetMs: 0, systemStartOffsetMs: systemOffsetMs,
                sampleRate: 16_000, conditioner: suppressor)
            return MeetingAecMetrics.erleDB(mic: mic, output: out.output, over: window)
        }

        let aligned = try erle(systemOffsetMs: leadMs)
        let misaligned = try erle(systemOffsetMs: 0)
        XCTAssertGreaterThan(
            aligned, misaligned + 6,
            "the recorded start offset realigns the reference and restores cancellation "
                + "(aligned \(aligned) dB vs ignoring-offset \(misaligned) dB)")
    }

    // MARK: I/O round-trip

    func testRenderProducesDecodableCleanedFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scenario = MeetingAecScenarioFactory.make(
            name: "double-talk", nearEndActive: true, farEndActive: true, echoPath: echoPath)
        let micURL = dir.appendingPathComponent("microphone-raw.m4a")
        let sysURL = dir.appendingPathComponent("system-raw.m4a")
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

    func testRenderSkipsNoEchoPathBeforeLoadingConditioner() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scenario = MeetingAecScenarioFactory.make(
            name: "headphones-no-echo",
            nearEndActive: true,
            farEndActive: true,
            echoPath: MeetingAecEchoPath(taps: []),
            noiseLevel: 0.0001
        )
        let (micURL, sysURL) = try await writeSourcePair(in: dir, scenario: scenario)
        let factoryProbe = RendererConditionerFactoryProbe {
            StreamingMeetingEchoSuppressor(
                processor: MeetingAecNLMSProcessor(),
                referenceDelaySamples: 120
            )
        }
        let outURL = dir.appendingPathComponent(MeetingCleanedMicRenderer.cleanedMicrophoneFileName)

        let outcome = try await MeetingCleanedMicRenderer().render(
            microphoneURL: micURL,
            systemURL: sysURL,
            sourceAlignment: equalAlignment(),
            outputURL: outURL,
            conditionerFactory: { factoryProbe.make() }
        )

        guard case .skipped(.noEchoPath(let probe)) = outcome else {
            return XCTFail("expected no-echo skip, got \(outcome)")
        }
        XCTAssertEqual(factoryProbe.buildCount, 0, "no-echo meetings must not load the model")
        XCTAssertGreaterThan(probe.windowsEvaluated, 0)
        XCTAssertLessThan(
            probe.bestCorrelation ?? 0,
            MeetingCleanedMicRenderer.echoProbeCorrelationThreshold
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL.path))
    }

    func testRenderSkipsRemoteSilentReferenceBeforeLoadingConditioner() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scenario = MeetingAecScenarioFactory.make(
            name: "remote-silent",
            nearEndActive: true,
            farEndActive: false,
            echoPath: echoPath
        )
        let (micURL, sysURL) = try await writeSourcePair(in: dir, scenario: scenario)
        let factoryProbe = RendererConditionerFactoryProbe {
            StreamingMeetingEchoSuppressor(
                processor: MeetingAecNLMSProcessor(),
                referenceDelaySamples: 120
            )
        }

        let outcome = try await MeetingCleanedMicRenderer().render(
            microphoneURL: micURL,
            systemURL: sysURL,
            sourceAlignment: equalAlignment(),
            outputURL: dir.appendingPathComponent(MeetingCleanedMicRenderer.cleanedMicrophoneFileName),
            conditionerFactory: { factoryProbe.make() }
        )

        guard case .skipped(.noEchoPath(let probe)) = outcome else {
            return XCTFail("expected remote-silent skip, got \(outcome)")
        }
        XCTAssertEqual(factoryProbe.buildCount, 0)
        XCTAssertEqual(probe.windowsEvaluated, 0)
        XCTAssertEqual(probe.detail, "no_reference_energy")
        XCTAssertNil(probe.bestCorrelation)
    }

    func testRenderProceedsForQuietBleed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let quietEchoPath = MeetingAecEchoPath(taps: [(delay: 120, gain: 0.08)])
        let scenario = MeetingAecScenarioFactory.make(
            name: "quiet-bleed",
            nearEndActive: false,
            farEndActive: true,
            echoPath: quietEchoPath,
            noiseLevel: 0.0001,
            farAmplitude: 0.12
        )
        let (micURL, sysURL) = try await writeSourcePair(in: dir, scenario: scenario)
        let outURL = dir.appendingPathComponent(MeetingCleanedMicRenderer.cleanedMicrophoneFileName)

        let outcome = try await MeetingCleanedMicRenderer().render(
            microphoneURL: micURL,
            systemURL: sysURL,
            sourceAlignment: equalAlignment(),
            outputURL: outURL,
            conditionerFactory: {
                StreamingMeetingEchoSuppressor(
                    processor: MeetingAecNLMSProcessor(),
                    referenceDelaySamples: 120
                )
            }
        )

        guard case .rendered(let result) = outcome else {
            return XCTFail("expected quiet bleed to render, got \(outcome)")
        }
        XCTAssertGreaterThan(
            result.echoProbe.bestCorrelation ?? 0,
            MeetingCleanedMicRenderer.echoProbeCorrelationThreshold
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }

    func testEchoProbeCatchesLateEchoWindow() {
        let sampleRate = 16_000
        let sampleCount = sampleRate * 40
        let tailStart = sampleRate * 30
        let tailLength = sampleRate * 10
        let farTail = MeetingAecSignal.voiceLike(
            sampleCount: tailLength,
            sampleRate: Float(sampleRate),
            formants: MeetingAecScenarioFactory.farFormants,
            seed: MeetingAecScenarioFactory.farSeed,
            amplitude: 0.25
        )
        var system = [Float](repeating: 0, count: sampleCount)
        for index in 0..<tailLength {
            system[tailStart + index] = farTail[index]
        }
        let mic = echoPath.apply(to: system)

        let probe = MeetingCleanedMicRenderer.probeEchoPath(
            microphone: mic,
            system: system,
            microphoneStartOffsetMs: 0,
            systemStartOffsetMs: 0,
            sampleRate: sampleRate
        )

        XCTAssertTrue(probe.shouldRender)
        XCTAssertEqual(probe.detail, "echo_detected")
        XCTAssertGreaterThan(probe.windowsEvaluated, 0)
        XCTAssertGreaterThan(
            probe.bestCorrelation ?? 0,
            MeetingCleanedMicRenderer.echoProbeCorrelationThreshold
        )
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
            systemURL: dir.appendingPathComponent("system-raw.m4a"),
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
        return try await writeSourcePair(in: dir, scenario: scenario, includeSystem: includeSystem)
    }

    @discardableResult
    private func writeSourcePair(
        in dir: URL,
        scenario: MeetingAecScenario,
        includeSystem: Bool = true
    ) async throws -> (URL, URL) {
        let micURL = dir.appendingPathComponent("microphone-raw.m4a")
        let sysURL = dir.appendingPathComponent("system-raw.m4a")
        try await MeetingCleanedMicRenderer.encodeMonoFloat(
            scenario.mic, sampleRate: 16_000, to: micURL, fileManager: .default)
        if includeSystem {
            try await MeetingCleanedMicRenderer.encodeMonoFloat(
                scenario.farEnd, sampleRate: 16_000, to: sysURL, fileManager: .default)
        }
        return (micURL, sysURL)
    }
}

private final class RendererConditionerFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let factory: @Sendable () -> any MicConditioning
    private var count = 0

    var buildCount: Int {
        lock.withLock { count }
    }

    init(factory: @escaping @Sendable () -> any MicConditioning) {
        self.factory = factory
    }

    func make() -> any MicConditioning {
        lock.withLock {
            count += 1
        }
        return factory()
    }
}

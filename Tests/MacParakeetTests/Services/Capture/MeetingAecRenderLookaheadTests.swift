import XCTest
@testable import MacParakeetCore

/// Env-gated check that the renderer's reference lookahead (#920) still lets the
/// real LocalVQE model remove an echo that leads the recorded reference while
/// keeping the local voice. Skipped in normal CI; run locally with:
///
///   MACPARAKEET_TEST_LOCALVQE_LIBRARY=/path/to/liblocalvqe.dylib \
///   MACPARAKEET_TEST_LOCALVQE_MODEL=/path/to/localvqe-v1.4-aec-200K-f32.gguf \
///   swift test --filter MeetingAecRenderLookaheadTests
final class MeetingAecRenderLookaheadTests: XCTestCase {
    private static let libraryKey = "MACPARAKEET_TEST_LOCALVQE_LIBRARY"
    private static let modelKey = "MACPARAKEET_TEST_LOCALVQE_MODEL"
    /// The recorded offset places the reference this late relative to its echo,
    /// inside the −1 to −9 ms range measured on the #920 meeting.
    private static let recordedReferenceLagMs = 8
    private let echoPath = MeetingAecEchoPath(taps: [(delay: 0, gain: 0.6), (delay: 48, gain: 0.2)])

    func testLocalVQERemovesLeadingEchoAndKeepsLocalVoice() throws {
        let (libraryURL, modelURL) = try assetURLs()
        func render(_ scenario: MeetingAecScenario) throws -> [Float] {
            try MeetingCleanedMicRenderer.alignAndCondition(
                microphone: scenario.mic, system: scenario.farEnd,
                microphoneStartOffsetMs: 0, systemStartOffsetMs: Self.recordedReferenceLagMs,
                sampleRate: MeetingCleanedMicRenderer.renderSampleRate,
                conditioner: try makeConditioner(libraryURL: libraryURL, modelURL: modelURL)
            ).output
        }

        let far = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true, echoPath: echoPath)
        let erle = MeetingAecMetrics.erleDB(
            mic: far.mic, output: try render(far), over: far.steadyStateWindow)

        let near = MeetingAecScenarioFactory.make(
            name: "near-end-only", nearEndActive: true, farEndActive: false, echoPath: echoPath)
        let retention = MeetingAecMetrics.rmsRatio(
            try render(near), reference: near.mic, over: near.steadyStateWindow)

        let doubleTalk = MeetingAecScenarioFactory.makeDoubleTalk(
            name: "double-talk-6db", echoPath: echoPath, signalToInterferenceDB: 6)
        let window = doubleTalk.steadyStateWindow
        let cleanError = MeetingAecMetrics.nearEndErrorDB(
            output: try render(doubleTalk), nearEnd: doubleTalk.nearEnd, over: window)
        let rawError = MeetingAecMetrics.nearEndErrorDB(
            output: doubleTalk.mic, nearEnd: doubleTalk.nearEnd, over: window)

        print(
            String(
                format:
                    "[AEC-LOOKAHEAD] ERLE %.1f dB, near-end retention %.2f, double-talk error %.1f dB (raw %.1f dB)",
                erle, retention, cleanError, rawError))
        // Same robust axes as MeetingAecModelScoringTests' release gate. The
        // double-talk error is reported, not gated: LocalVQE reshapes the tonal
        // fixture, so waveform error cannot certify fidelity.
        XCTAssertGreaterThan(erle, 15, "leading echo is removed")
        XCTAssertGreaterThan(retention, 0.8, "local voice keeps its energy")
        XCTAssertLessThan(retention, 1.5, "local voice is not amplified")
    }

    private func assetURLs() throws -> (URL, URL) {
        let env = ProcessInfo.processInfo.environment
        guard let libraryPath = env[Self.libraryKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !libraryPath.isEmpty,
            let modelPath = env[Self.modelKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !modelPath.isEmpty
        else {
            throw XCTSkip("Set \(Self.libraryKey) and \(Self.modelKey) to run real LocalVQE lookahead checks.")
        }
        let libraryURL = URL(fileURLWithPath: libraryPath)
        let modelURL = URL(fileURLWithPath: modelPath)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libraryURL.path), "Missing LocalVQE library.")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelURL.path), "Missing LocalVQE model.")
        return (libraryURL, modelURL)
    }

    private func makeConditioner(libraryURL: URL, modelURL: URL) throws -> any MicConditioning {
        let conditioner = MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: libraryURL,
                modelURL: modelURL,
                sampleRate: MeetingCleanedMicRenderer.renderSampleRate))
        // The assets were opted in and exist, so a load failure is a regression.
        return try XCTUnwrap(
            conditioner.diagnostics.loaded ? conditioner : nil, "LocalVQE conditioner did not load.")
    }
}

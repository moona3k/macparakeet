import XCTest
@testable import MacParakeetCore

/// Env-gated timing probe for the production cleaned-mic conditioning core with
/// real LocalVQE assets. This is intentionally skipped in normal CI; run locally with:
///
///   MACPARAKEET_TEST_LOCALVQE_LIBRARY=/path/to/liblocalvqe.dylib \
///   MACPARAKEET_TEST_LOCALVQE_MODEL=/path/to/localvqe-v1.4-aec-200K-f32.gguf \
///   swift test --filter MeetingAecRenderThroughputTests
final class MeetingAecRenderThroughputTests: XCTestCase {
    private static let libraryKey = "MACPARAKEET_TEST_LOCALVQE_LIBRARY"
    private static let modelKey = "MACPARAKEET_TEST_LOCALVQE_MODEL"

    func testLocalVQECleanedMicRenderThroughput() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let libraryPath = env[Self.libraryKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !libraryPath.isEmpty,
              let modelPath = env[Self.modelKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelPath.isEmpty else {
            throw XCTSkip("Set \(Self.libraryKey) and \(Self.modelKey) to measure real LocalVQE render throughput.")
        }

        let libraryURL = URL(fileURLWithPath: libraryPath)
        let modelURL = URL(fileURLWithPath: modelPath)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libraryURL.path), "Missing LocalVQE library.")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelURL.path), "Missing LocalVQE model.")

        let seconds = 60
        let sampleRate = MeetingCleanedMicRenderer.renderSampleRate
        let scenario = MeetingAecScenarioFactory.make(
            name: "localvqe-render-throughput",
            nearEndActive: true,
            farEndActive: true,
            echoPath: MeetingAecEchoPath(
                taps: [(delay: 120, gain: 0.6), (delay: 180, gain: 0.25), (delay: 240, gain: 0.12)]
            ),
            sampleCount: seconds * sampleRate
        )

        let conditioner = MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: libraryURL,
                modelURL: modelURL,
                sampleRate: sampleRate,
                frameSize: MeetingEchoSuppressionConfiguration.defaultFrameSize,
                adaptiveReferenceDelay: false
            )
        )
        try XCTSkipUnless(conditioner.diagnostics.loaded, "LocalVQE conditioner did not load.")

        let started = ContinuousClock.now
        let result = try MeetingCleanedMicRenderer.alignAndCondition(
            microphone: scenario.mic,
            system: scenario.farEnd,
            microphoneStartOffsetMs: 0,
            systemStartOffsetMs: 0,
            sampleRate: sampleRate,
            conditioner: conditioner
        )
        let elapsed = started.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        let audioSeconds = Double(result.output.count) / Double(sampleRate)
        let realtimeFactor = audioSeconds / elapsedSeconds
        print(String(
            format: "[AEC-THROUGHPUT] LocalVQE cleaned-mic conditioning: audio %.1fs elapsed %.3fs throughput %.2fx failures %ld",
            audioSeconds,
            elapsedSeconds,
            realtimeFactor,
            result.processingFailures
        ))
        XCTAssertEqual(result.output.count, scenario.sampleCount)
        XCTAssertEqual(result.processingFailures, 0)
    }
}

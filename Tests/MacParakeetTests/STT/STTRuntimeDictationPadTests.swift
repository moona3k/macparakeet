import AVFoundation
import FluidAudio
@testable import MacParakeetCore
import XCTest

/// Unit coverage for the dictation trailing-silence pad (issue #562). The
/// CoreML Parakeet model cannot run in CI, so these exercise the padding
/// mechanism and the WAV decode round-trip that feed it, not the WER outcome.
final class STTRuntimeDictationPadTests: XCTestCase {
    // MARK: - appendingTrailingSilence

    func testAppendingTrailingSilenceAddsZeroPaddedTail() {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let padded = STTRuntime.appendingTrailingSilence(samples, seconds: 0.5, sampleRate: 16_000)

        XCTAssertEqual(padded.count, samples.count + 8_000)
        XCTAssertEqual(Array(padded.prefix(samples.count)), samples)
        XCTAssertTrue(padded.suffix(8_000).allSatisfy { $0 == 0 })
    }

    func testAppendingTrailingSilenceUsesProductionDuration() {
        let samples = [Float](repeating: 0.5, count: 1_000)
        let padded = STTRuntime.appendingTrailingSilence(
            samples,
            seconds: STTRuntime.dictationTrailingSilenceSeconds,
            sampleRate: ASRConstants.sampleRate
        )
        let expectedPad = Int(STTRuntime.dictationTrailingSilenceSeconds * Double(ASRConstants.sampleRate))

        XCTAssertEqual(padded.count, samples.count + expectedPad)
    }

    func testAppendingTrailingSilenceIsNoOpForEmptyOrNonPositiveInputs() {
        XCTAssertTrue(STTRuntime.appendingTrailingSilence([], seconds: 0.5, sampleRate: 16_000).isEmpty)

        let samples: [Float] = [0.1, 0.2]
        XCTAssertEqual(STTRuntime.appendingTrailingSilence(samples, seconds: 0, sampleRate: 16_000), samples)
        XCTAssertEqual(STTRuntime.appendingTrailingSilence(samples, seconds: -1, sampleRate: 16_000), samples)
        XCTAssertEqual(STTRuntime.appendingTrailingSilence(samples, seconds: 0.5, sampleRate: 0), samples)
    }

    // MARK: - decode + pad round-trip

    func testPaddedDictationSamplesDecodesWavAndAppendsSilence() throws {
        let realSampleCount = 4_800  // 0.3 s at 16 kHz
        let url = try writeMonoFloatWav(
            sampleCount: realSampleCount,
            sampleRate: 16_000,
            valueAt: { Float(sin(Double($0) * 0.05)) }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = STTRuntime.loadShortDictationSamples16k(path: url.path, maxSamples: ASRConstants.maxModelSamples)
        XCTAssertEqual(decoded?.count, realSampleCount)

        let padded = STTRuntime.paddedDictationSamples(audioPath: url.path)
        let expectedPad = Int(STTRuntime.dictationTrailingSilenceSeconds * Double(ASRConstants.sampleRate))
        XCTAssertEqual(padded.count, realSampleCount + expectedPad)
        XCTAssertTrue(padded.suffix(expectedPad).allSatisfy { $0 == 0 })
        // The real audio is preserved ahead of the silence.
        XCTAssertFalse(padded.prefix(realSampleCount).allSatisfy { $0 == 0 })
    }

    func testCustomVocabularySidecarReceivesPaddedDictationSamples() async throws {
        let realSampleCount = 4_800  // 0.3 s at 16 kHz
        let url = try writeMonoFloatWav(
            sampleCount: realSampleCount,
            sampleRate: 16_000,
            valueAt: { Float(sin(Double($0) * 0.05)) }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let padded = STTRuntime.paddedDictationSamples(audioPath: url.path)
        let rescorer = DictationPadCustomVocabularyRescorer(text: "MacParakeet")
        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "MAC Parakeet",
            tokenTimings: [
                TokenTiming(token: "▁MAC", tokenId: 1, startTime: 0.0, endTime: 0.2, confidence: 0.9),
                TokenTiming(token: "▁Parakeet", tokenId: 2, startTime: 0.2, endTime: 0.6, confidence: 0.9),
            ],
            audioSamples: padded,
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer
        )

        XCTAssertEqual(result.text, "MacParakeet")
        let requests = await rescorer.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let requestSamples = requests[0].audioSamples
        let expectedPad = Int(STTRuntime.dictationTrailingSilenceSeconds * Double(ASRConstants.sampleRate))
        XCTAssertEqual(requestSamples.count, realSampleCount + expectedPad)
        XCTAssertEqual(requestSamples, padded)
        XCTAssertTrue(requestSamples.suffix(expectedPad).allSatisfy { $0 == 0 })
    }

    func testPaddedDictationSamplesFallsThroughWhenPadWouldExceedSingleWindow() throws {
        // A clip whose padded length would cross the single-window limit must
        // stay on FluidAudio's URL path instead of being loaded and padded in
        // memory.
        let padSamples = Int(STTRuntime.dictationTrailingSilenceSeconds * Double(ASRConstants.sampleRate))
        let longSampleCount = ASRConstants.maxModelSamples - padSamples + 1
        let url = try writeMonoFloatWav(
            sampleCount: longSampleCount,
            sampleRate: 16_000,
            valueAt: { _ in 0.1 }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNotNil(STTRuntime.loadShortDictationSamples16k(path: url.path, maxSamples: ASRConstants.maxModelSamples))
        XCTAssertNil(STTRuntime.loadShortDictationSamples16k(
            path: url.path,
            maxSamples: ASRConstants.maxModelSamples - padSamples
        ))
        XCTAssertTrue(STTRuntime.paddedDictationSamples(audioPath: url.path).isEmpty)
    }

    func testShortSampleLoaderPropagatesCancellation() throws {
        let url = try writeMonoFloatWav(
            sampleCount: 1_000,
            sampleRate: 16_000,
            valueAt: { _ in 0.1 }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try STTRuntime.loadShortDictationSamples16k(
                path: url.path,
                maxSamples: ASRConstants.maxModelSamples,
                checkCancellation: {
                    throw CancellationError()
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPaddedDictationSamplesIsEmptyForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        XCTAssertTrue(STTRuntime.paddedDictationSamples(audioPath: missing.path).isEmpty)
        XCTAssertNil(STTRuntime.loadShortDictationSamples16k(path: missing.path, maxSamples: ASRConstants.maxModelSamples))
    }

    // MARK: - helpers

    /// Writes a 16 kHz mono Float32 WAV, matching `AudioRecorder`'s dictation
    /// output format, so the decode path under test sees a realistic file.
    private func writeMonoFloatWav(
        sampleCount: Int,
        sampleRate: Double,
        valueAt: (Int) -> Float
    ) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))!
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let channel = buffer.floatChannelData![0]
        for index in 0..<sampleCount {
            channel[index] = valueAt(index)
        }
        try file.write(from: buffer)
        return url
    }
}

private actor DictationPadCustomVocabularyRescorer: CustomVocabularyRescoring {
    private var requests: [CustomVocabularyRescoringRequest] = []
    private let text: String

    init(text: String) {
        self.text = text
    }

    func rescore(_ request: CustomVocabularyRescoringRequest) async throws -> CustomVocabularyRescoringResult {
        requests.append(request)
        return CustomVocabularyRescoringResult(
            text: text,
            detectedTerms: request.vocabulary.terms,
            appliedTerms: request.vocabulary.terms,
            replacementCount: request.vocabulary.terms.count
        )
    }

    func recordedRequests() -> [CustomVocabularyRescoringRequest] {
        requests
    }
}

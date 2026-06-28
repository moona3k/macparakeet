import FluidAudio
@testable import MacParakeetCore
import XCTest

final class ParakeetUnifiedEngineDictationPadTests: XCTestCase {
    func testDictationSamplesAppendTrailingSilence() {
        let samples: [Float] = [0.1, -0.2, 0.3]

        let padded = ParakeetUnifiedEngine.samplesForOfflineTranscription(
            samples,
            job: .dictation
        )

        let expectedPad = Int(STTRuntime.dictationTrailingSilenceSeconds * Double(ASRConstants.sampleRate))
        XCTAssertEqual(padded.count, samples.count + expectedPad)
        XCTAssertEqual(Array(padded.prefix(samples.count)), samples)
        XCTAssertTrue(padded.suffix(expectedPad).allSatisfy { $0 == 0 })
    }

    func testNonDictationSamplesAreUnchanged() {
        let samples: [Float] = [0.1, -0.2, 0.3]

        let meetingSamples = ParakeetUnifiedEngine.samplesForOfflineTranscription(
            samples,
            job: .meetingFinalize
        )

        XCTAssertEqual(meetingSamples, samples)
    }
}

import XCTest
@testable import MacParakeetCore

final class MeetingSoftwareAECTests: XCTestCase {
    func testProcessPassesThroughMicrophoneWhenSpeakerIsSilent() {
        let aec = MeetingSoftwareAEC()
        let mic: [Float] = [0.1, -0.2, 0.3, -0.4, 0.0, 0.25]
        let speaker = [Float](repeating: 0, count: mic.count)

        let output = aec.process(microphone: mic, speaker: speaker)
        XCTAssertEqual(output, mic)
    }

    func testProcessReducesSyntheticEchoEnergy() {
        let aec = MeetingSoftwareAEC()
        let sampleRate: Float = 16_000
        let totalSamples = 16_000
        let echoDelay = 48
        let echoGain: Float = 0.75

        var speaker = [Float](repeating: 0, count: totalSamples)
        for index in 0..<totalSamples {
            let t = Float(index) / sampleRate
            speaker[index] = sinf(2 * .pi * 440 * t)
        }

        var microphone = [Float](repeating: 0, count: totalSamples)
        for index in 0..<totalSamples where index - echoDelay >= 0 {
            microphone[index] = speaker[index - echoDelay] * echoGain
        }

        var processed: [Float] = []
        processed.reserveCapacity(totalSamples)
        let chunkSize = 160
        var offset = 0
        while offset < totalSamples {
            let end = min(offset + chunkSize, totalSamples)
            let chunkOut = aec.process(
                microphone: Array(microphone[offset..<end]),
                speaker: Array(speaker[offset..<end])
            )
            processed.append(contentsOf: chunkOut)
            offset = end
        }

        let inputRms = rms(microphone)
        let outputRms = rms(processed)
        XCTAssertGreaterThan(inputRms, 0.01)
        XCTAssertLessThan(outputRms, inputRms * 0.80)
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(samples.count))
    }
}

import XCTest
@testable import MacParakeetCore

/// The fixed adapter is the production default and fallback path; it must stay
/// byte-identical to `AudioChunker`.
final class FixedMeetingLiveAudioChunkerTests: XCTestCase {
    func testMatchesAudioChunkerForSteadyStream() async {
        let adapter = FixedMeetingLiveAudioChunker()
        let reference = AudioChunker()

        // Feed several 8 000-sample batches (0.5s each) and compare emissions.
        var adapterChunks: [AudioChunker.AudioChunk] = []
        var referenceChunks: [AudioChunker.AudioChunk] = []
        for _ in 0..<30 {
            let batch = [Float](repeating: 0.2, count: 8_000)
            adapterChunks += await adapter.addSamples(batch)
            if let chunk = await reference.addSamples(batch) {
                referenceChunks.append(chunk)
            }
        }

        XCTAssertEqual(adapterChunks.count, referenceChunks.count)
        XCTAssertFalse(adapterChunks.isEmpty)
        for (lhs, rhs) in zip(adapterChunks, referenceChunks) {
            XCTAssertEqual(lhs.startMs, rhs.startMs)
            XCTAssertEqual(lhs.endMs, rhs.endMs)
            XCTAssertEqual(lhs.samples, rhs.samples)
        }
    }

    func testFlushMatchesAudioChunker() async {
        let adapter = FixedMeetingLiveAudioChunker()
        let reference = AudioChunker()

        let batch = [Float](repeating: 0.3, count: 20_000)  // > minimum, < chunk
        _ = await adapter.addSamples(batch)
        _ = await reference.addSamples(batch)

        let adapterFlush = await adapter.flush()
        let referenceFlush = await reference.flush()

        XCTAssertEqual(adapterFlush?.startMs, referenceFlush?.startMs)
        XCTAssertEqual(adapterFlush?.endMs, referenceFlush?.endMs)
        XCTAssertEqual(adapterFlush?.samples, referenceFlush?.samples)
    }

    func testResetClearsState() async {
        let adapter = FixedMeetingLiveAudioChunker()
        _ = await adapter.addSamples([Float](repeating: 0.1, count: 80_000))
        await adapter.reset()

        // After reset the timeline restarts at 0.
        let chunks = await adapter.addSamples([Float](repeating: 0.1, count: 80_000))
        XCTAssertEqual(chunks.first?.startMs, 0)
    }
}

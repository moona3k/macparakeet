import XCTest
@testable import MacParakeetCore

/// A test double for any `STTTranscribing` engine. Records calls, supports
/// per-path canned results and per-path errors. Fires (0, 100) and then
/// (100, 100) on the progress callback to mimic the real engine's contract.
final class FakeVibeVoiceTranscribing: STTTranscribing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeVibeVoiceTranscribing.state")
    private var _resultsByPath: [String: [STTSegment]] = [:]
    private var _shouldThrowOnPath: String? = nil
    private var _callLog: [(path: String, job: STTJobKind)] = []

    func setResults(forPath path: String, segments: [STTSegment]) {
        queue.sync { _resultsByPath[path] = segments }
    }

    func setShouldThrow(onPath path: String) {
        queue.sync { _shouldThrowOnPath = path }
    }

    var callLog: [(path: String, job: STTJobKind)] {
        queue.sync { _callLog }
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        queue.sync { _callLog.append((path: audioPath, job: job)) }
        let shouldThrow: Bool = queue.sync { _shouldThrowOnPath == audioPath }
        if shouldThrow {
            throw STTError.transcriptionFailed("fake fail: \(audioPath)")
        }
        onProgress?(0, 100)
        let segments: [STTSegment] = queue.sync { _resultsByPath[audioPath] ?? [] }
        onProgress?(100, 100)
        return STTResult(
            text: segments.map(\.text).joined(separator: "\n"),
            words: [],
            segments: segments,
            language: nil,
            engine: .vibevoice,
            engineVariant: "fake"
        )
    }
}

final class VibeVoiceChunkedTranscriberConstructorTests: XCTestCase {
    func testInitializesWithDefaults() async {
        let fake = FakeVibeVoiceTranscribing()
        let chunker = VibeVoiceChunkedTranscriber(engine: fake)
        _ = chunker  // ensure init compiles and doesn't crash
    }
}

final class VibeVoiceChunkedTranscriberOrchestrationTests: XCTestCase {

    fileprivate func fixtureURL() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // STT/
            .appendingPathComponent("Fixtures/synthetic_silence.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "synthetic_silence.wav fixture missing — run scripts/dev/make_silence_fixture.sh")
        return url
    }

    /// 60-s fixture, chunkLengthSec=20 → 3 chunks. Silences at 20-22 s and
    /// 40-42 s mean boundaries should snap there. Fake engine returns one
    /// canned segment per chunk; the merger combines them with offsets.
    func testHappyPathThreeChunksMergedWithOffsets() async throws {
        let fixture = try fixtureURL()
        let recorder = SegmentInjectingFake()
        recorder.injectedSegments = [
            [STTSegment(startMs: 0, endMs: 18_000, text: "chunk0", speakerId: 0)],
            [STTSegment(startMs: 0, endMs: 18_000, text: "chunk1", speakerId: 0)],
            [STTSegment(startMs: 0, endMs: 15_000, text: "chunk2", speakerId: 0)],
        ]
        let chunker = VibeVoiceChunkedTranscriber(
            engine: recorder,
            chunkLengthSec: 20,
            minTailSec: 5,
            silenceWindowSec: 5
        )
        let result = try await chunker.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            onProgress: nil
        )
        // Three chunks were processed
        XCTAssertEqual(recorder.callCount, 3)
        // Three merged segments, with offsets matching refined boundaries.
        // Boundaries: target 20 s snaps to ~21 (mid of silence 20-22),
        //             target 40 s snaps to ~41 (mid of silence 40-42).
        let segments = try XCTUnwrap(result.segments)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].startMs, 0)
        XCTAssertEqual(segments[0].text, "chunk0")
        // Chunk 1 starts at refined boundary (≈ 21 s = 21000 ms)
        XCTAssertEqual(Double(segments[1].startMs), 21000, accuracy: 200)
        XCTAssertEqual(segments[1].text, "chunk1")
        // Chunk 2 starts at refined boundary (≈ 41 s = 41000 ms)
        XCTAssertEqual(Double(segments[2].startMs), 41000, accuracy: 200)
        XCTAssertEqual(segments[2].text, "chunk2")
        // Engine variant tagged as chunked
        XCTAssertEqual(result.engineVariant, "vibevoice-asr-q4_k-chunked")
        XCTAssertEqual(result.engine, .vibevoice)
        XCTAssertTrue(result.words.isEmpty)
    }

    /// If a single chunk's engine.transcribe throws, the whole transcribe
    /// call throws. No partial transcript is returned.
    func testThrowingChunkFailsWholeJob() async throws {
        let fixture = try fixtureURL()
        let thrower = ThrowingOnSecondCallFake()
        let chunker = VibeVoiceChunkedTranscriber(
            engine: thrower,
            chunkLengthSec: 20,
            minTailSec: 5,
            silenceWindowSec: 5
        )
        do {
            _ = try await chunker.transcribe(
                audioPath: fixture.path,
                job: .fileTranscription,
                onProgress: nil
            )
            XCTFail("Expected throw from chunked transcribe")
        } catch let error as STTError {
            // Expected — propagated from the inner engine's STTError.
            switch error {
            case .transcriptionFailed(let msg):
                XCTAssertTrue(msg.contains("fake chunk 2"), "Got: \(msg)")
            default:
                XCTFail("Unexpected STTError: \(error)")
            }
        }
        // The fake should have been called exactly twice (chunk 0 succeeded,
        // chunk 1 threw, chunk 2 was never invoked).
        XCTAssertEqual(thrower.callCount, 2)
    }

    /// Temp chunk files are removed even when the loop throws mid-way.
    func testCleanupRunsOnFailure() async throws {
        let fixture = try fixtureURL()
        let thrower = ThrowingOnSecondCallFake()
        let chunker = VibeVoiceChunkedTranscriber(
            engine: thrower,
            chunkLengthSec: 20,
            minTailSec: 5,
            silenceWindowSec: 5
        )
        let tempDirBefore = try countVvChunkFilesInTempDir()
        _ = try? await chunker.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            onProgress: nil
        )
        // Allow defer to run on the failing path
        let tempDirAfter = try countVvChunkFilesInTempDir()
        XCTAssertEqual(tempDirBefore, tempDirAfter,
                       "Temp vv-chunk-* files should have been cleaned up after failure")
    }

    private func countVvChunkFilesInTempDir() throws -> Int {
        let tempDir = FileManager.default.temporaryDirectory
        let all = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        return all.filter { $0.hasPrefix("vv-chunk-") && $0.hasSuffix(".wav") }.count
    }

    func testProgressIsMonotonicAndEndsAt100() async throws {
        let fixture = try fixtureURL()
        let fake = SegmentInjectingFake()
        fake.injectedSegments = [
            [STTSegment(startMs: 0, endMs: 1000, text: "a", speakerId: 0)],
            [STTSegment(startMs: 0, endMs: 1000, text: "b", speakerId: 0)],
            [STTSegment(startMs: 0, endMs: 1000, text: "c", speakerId: 0)],
        ]
        // Capture every (current, total) callback into a thread-safe list.
        let progressLog = ProgressLog()
        let onProgress: @Sendable (Int, Int) -> Void = { current, total in
            progressLog.append((current, total))
        }
        let chunker = VibeVoiceChunkedTranscriber(
            engine: fake,
            chunkLengthSec: 20,
            minTailSec: 5,
            silenceWindowSec: 5
        )
        _ = try await chunker.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            onProgress: onProgress
        )
        let snapshot = progressLog.values
        XCTAssertFalse(snapshot.isEmpty, "Expected at least one progress callback")
        // All totals should be 100
        for (_, total) in snapshot {
            XCTAssertEqual(total, 100)
        }
        // Currents must be monotonically non-decreasing
        var prev = -1
        for (current, _) in snapshot {
            XCTAssertGreaterThanOrEqual(current, prev,
                "Progress went backward in sequence: \(snapshot)")
            prev = current
        }
        // Final value is 100
        XCTAssertEqual(snapshot.last?.0, 100)
    }
}

/// A fake that succeeds on the first call and throws on the second.
final class ThrowingOnSecondCallFake: STTTranscribing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ThrowingOnSecondCallFake")
    private var _callCount = 0
    var callCount: Int { queue.sync { _callCount } }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let index: Int = queue.sync {
            let current = _callCount
            _callCount += 1
            return current
        }
        if index == 1 {
            throw STTError.transcriptionFailed("fake chunk 2")
        }
        onProgress?(0, 100)
        onProgress?(100, 100)
        return STTResult(
            text: "",
            words: [],
            segments: [],
            language: nil,
            engine: .vibevoice,
            engineVariant: "fake"
        )
    }
}

/// A more controllable fake that returns a different segment per call,
/// in call order. Used when test setup doesn't know chunk paths in advance.
final class SegmentInjectingFake: STTTranscribing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SegmentInjectingFake")
    private var _injectedSegments: [[STTSegment]] = []
    private var _callCount = 0

    var injectedSegments: [[STTSegment]] {
        get { queue.sync { _injectedSegments } }
        set { queue.sync { _injectedSegments = newValue } }
    }
    var callCount: Int { queue.sync { _callCount } }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let segments: [STTSegment] = queue.sync {
            defer { _callCount += 1 }
            return _callCount < _injectedSegments.count ? _injectedSegments[_callCount] : []
        }
        onProgress?(0, 100)
        onProgress?(100, 100)
        return STTResult(
            text: segments.map(\.text).joined(separator: "\n"),
            words: [],
            segments: segments,
            language: nil,
            engine: .vibevoice,
            engineVariant: "fake"
        )
    }
}

final class ProgressLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ProgressLog")
    private var _values: [(Int, Int)] = []
    func append(_ value: (Int, Int)) { queue.sync { _values.append(value) } }
    var values: [(Int, Int)] { queue.sync { _values } }
}

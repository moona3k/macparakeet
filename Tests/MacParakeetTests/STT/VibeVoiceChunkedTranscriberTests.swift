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

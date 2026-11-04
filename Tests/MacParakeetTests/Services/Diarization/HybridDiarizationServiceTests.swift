import XCTest
@testable import MacParakeetCore

/// Nemotron timing fused with Community-1 identity.
final class HybridDiarizationServiceTests: XCTestCase {
    private let identity = SpeakerModelIdentity(embeddingModelId: "test-model", aggregationProfileId: "test-aggregation")

    // MARK: Fusion

    func testTimingSpeakersInheritTheMatchingVoice() throws {
        // Timing: A 0–10 s, B 10–20 s. Identity agrees but shifts the handover.
        let timing = result(["A": [(0, 10_000)], "B": [(10_000, 20_000)]])
        let identityResult = result(["S1": [(0, 11_000)], "S2": [(11_000, 20_000)]], voices: ["S1": 0, "S2": 1])

        let fused = try fusedResult(timing, identityResult)

        XCTAssertEqual(fused.segments.map(\.speakerId), ["A", "B"], "timing segments are kept")
        XCTAssertEqual(fused.speakerEmbeddings["A"], identityResult.speakerEmbeddings["S1"])
        XCTAssertEqual(fused.speakerEmbeddings["B"], identityResult.speakerEmbeddings["S2"])
        XCTAssertEqual(fused.speechMsBySpeaker, timing.speechMsBySpeaker)
    }

    func testTimingThatMergesTwoPeopleFallsBackToIdentity() {
        // One timing speaker covers two distinct voices of 30 s each.
        let timing = result(["A": [(0, 60_000)]])
        let identityResult = result(["S1": [(0, 30_000)], "S2": [(30_000, 60_000)]], voices: ["S1": 0, "S2": 1])

        guard case .identityOnly(let reason) = DiarizationFusion.fuse(timing: timing, identity: identityResult) else {
            return XCTFail("expected the identity result")
        }
        XCTAssertEqual(reason, .timingMergedDistinctVoices)
    }

    func testIdentityOverSplittingOnePersonIsNotAConflict() throws {
        // Community-1 split one person into two near-identical clusters.
        let timing = result(["A": [(0, 60_000)]])
        let identityResult = result(
            ["S1": [(0, 35_000)], "S2": [(35_000, 60_000)]], voices: ["S1": 0, "S2": 0], degrees: ["S2": 10])

        let fused = try fusedResult(timing, identityResult)

        XCTAssertEqual(fused.speakerEmbeddings["A"], identityResult.speakerEmbeddings["S1"])
    }

    func testOneVoiceIsGivenToOneTimingSpeakerOnly() throws {
        // Timing split one person (A 0–40 s, B 40–55 s) that identity kept whole.
        let timing = result(["A": [(0, 40_000)], "B": [(40_000, 55_000)]])
        let identityResult = result(["S1": [(0, 55_000)]], voices: ["S1": 0])

        let fused = try fusedResult(timing, identityResult)

        XCTAssertNotNil(fused.speakerEmbeddings["A"])
        XCTAssertNil(fused.speakerEmbeddings["B"], "two speakers must never carry the same voice")
    }

    func testAShortSecondVoiceDoesNotDiscardTheTiming() throws {
        // A brief 3 s of another voice inside A is boundary noise, not a merge.
        let timing = result(["A": [(0, 60_000)], "B": [(60_000, 90_000)]])
        let identityResult = result(
            ["S1": [(0, 57_000)], "S2": [(57_000, 90_000)]], voices: ["S1": 0, "S2": 1])

        let fused = try fusedResult(timing, identityResult)

        XCTAssertEqual(fused.speakerEmbeddings["A"], identityResult.speakerEmbeddings["S1"])
        XCTAssertEqual(fused.speakerEmbeddings["B"], identityResult.speakerEmbeddings["S2"])
    }

    func testAnUnclearTimingSpeakerKeepsItsSegmentsWithoutAVoice() throws {
        // C overlaps both voices evenly: below purity, so no identity.
        let timing = result(["A": [(0, 30_000)], "B": [(40_000, 70_000)], "C": [(30_000, 40_000)]])
        let identityResult = result(
            ["S1": [(0, 35_000)], "S2": [(35_000, 70_000)]], voices: ["S1": 0, "S2": 1])

        let fused = try fusedResult(timing, identityResult)

        XCTAssertNil(fused.speakerEmbeddings["C"])
        XCTAssertTrue(fused.segments.contains { $0.speakerId == "C" })
    }

    func testSpeechTheTimingMissedKeepsItsSpeaker() throws {
        // Timing hears nothing from 10–20 s; identity heard S1 to 15 s, then S2.
        let timing = result(["A": [(0, 10_000)], "B": [(20_000, 40_000)]])
        let identityResult = result(["S1": [(0, 15_000)], "S2": [(15_000, 40_000)]], voices: ["S1": 0, "S2": 1])

        let fused = try fusedResult(timing, identityResult)

        let fills = fused.segments.filter { $0.startMs >= 10_000 && $0.endMs <= 20_000 }
        XCTAssertEqual(fills.map(\.speakerId), ["A", "B"])
        XCTAssertEqual(fills.map(\.startMs), [10_000, 15_000])
        XCTAssertEqual(fills.map(\.endMs), [15_000, 20_000])
        XCTAssertEqual(fused.speechMsBySpeaker["A"], 15_000)
    }

    func testAVoiceWithoutATimingSpeakerFillsNoGap() throws {
        // S2 never maps to a timing speaker, so its stretch stays a gap.
        let timing = result(["A": [(0, 30_000)]])
        let identityResult = result(["S1": [(0, 30_000)], "S2": [(40_000, 45_000)]], voices: ["S1": 0, "S2": 1])

        let fused = try fusedResult(timing, identityResult)

        XCTAssertFalse(fused.segments.contains { $0.startMs >= 30_000 })
    }

    func testEmptyTimingFallsBackToIdentity() {
        let identityResult = result(["S1": [(0, 10_000)]], voices: ["S1": 0])
        guard case .identityOnly(.noTimingSpeech) = DiarizationFusion.fuse(timing: result([:]), identity: identityResult)
        else { return XCTFail("expected the identity result") }
    }

    // MARK: Service

    func testServiceFusesBothResults() async throws {
        let timing = result(["A": [(0, 10_000)], "B": [(10_000, 20_000)]])
        let identityResult = result(["S1": [(0, 10_000)], "S2": [(10_000, 20_000)]], voices: ["S1": 0, "S2": 1])
        let service = HybridDiarizationService(timing: Stub(.success(timing)), identity: Stub(.success(identityResult)))

        let output = try await service.diarize(audioURL: audioURL, speakerConstraint: nil)

        XCTAssertEqual(Set(output.speakerEmbeddings.keys), ["A", "B"])
    }

    func testTimingFailureReturnsTheIdentityResult() async throws {
        let identityResult = result(["S1": [(0, 10_000)]], voices: ["S1": 0])
        let service = HybridDiarizationService(
            timing: Stub(.failure(TestError.failed)), identity: Stub(.success(identityResult)))

        let output = try await service.diarize(audioURL: audioURL, speakerConstraint: nil)

        XCTAssertEqual(output.speakers.map(\.id), ["S1"])
        XCTAssertNotNil(output.speakerEmbeddings["S1"])
    }

    func testIdentityFailureKeepsTheTimingWithoutVoices() async throws {
        let timing = result(["A": [(0, 10_000)]])
        let service = HybridDiarizationService(
            timing: Stub(.success(timing)), identity: Stub(.failure(TestError.failed)))

        let output = try await service.diarize(audioURL: audioURL, speakerConstraint: nil)

        XCTAssertEqual(output.speakers.map(\.id), ["A"])
        XCTAssertTrue(output.speakerEmbeddings.isEmpty)
    }

    func testBothFailingThrows() async {
        let service = HybridDiarizationService(
            timing: Stub(.failure(TestError.failed)), identity: Stub(.failure(TestError.failed)))
        do {
            _ = try await service.diarize(audioURL: audioURL, speakerConstraint: nil)
            XCTFail("expected an error")
        } catch {}
    }

    func testCancellationIsNotSwallowed() async {
        let service = HybridDiarizationService(
            timing: Stub(.failure(CancellationError())), identity: Stub(.success(result([:]))))
        do {
            _ = try await service.diarize(audioURL: audioURL, speakerConstraint: nil)
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
    }

    func testTimingFallbackWithEmbeddingsIsReturnedAsIs() async throws {
        // Nemotron's own Community-1 fallback already carries identity.
        let fallback = result(["S1": [(0, 10_000)]], voices: ["S1": 0])
        let identityStub = Stub(.failure(TestError.failed))
        let service = HybridDiarizationService(timing: Stub(.success(fallback)), identity: identityStub)

        let output = try await service.diarize(audioURL: audioURL, speakerConstraint: .exact(1))

        XCTAssertEqual(output.speakerEmbeddings["S1"], fallback.speakerEmbeddings["S1"])
        let identityCalls = await identityStub.calls
        XCTAssertEqual(identityCalls, 0)
    }

    // MARK: Fixtures

    private enum TestError: Error { case failed }
    private var audioURL: URL { URL(fileURLWithPath: "/unused.wav") }

    private actor Stub: DiarizationServiceProtocol {
        let outcome: Result<MacParakeetDiarizationResult, Error>
        var calls = 0
        init(_ outcome: Result<MacParakeetDiarizationResult, Error>) { self.outcome = outcome }
        func diarize(audioURL: URL, speakerConstraint: SpeakerDiarizationConstraint?) async throws
            -> MacParakeetDiarizationResult
        {
            calls += 1
            return try outcome.get()
        }
        func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {}
        func isReady() async -> Bool { true }
        func hasCachedModels() async -> Bool { true }
    }

    private func fusedResult(
        _ timing: MacParakeetDiarizationResult, _ identityResult: MacParakeetDiarizationResult,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> MacParakeetDiarizationResult {
        guard case .fused(let fused, _) = DiarizationFusion.fuse(timing: timing, identity: identityResult) else {
            XCTFail("expected a fused result", file: file, line: line)
            throw TestError.failed
        }
        return fused
    }

    private func result(
        _ spans: [String: [(Int, Int)]], voices: [String: Int] = [:], degrees: [String: Double] = [:]
    ) -> MacParakeetDiarizationResult {
        let ids = spans.keys.sorted()
        let segments = ids.flatMap { id in spans[id]!.map { SpeakerSegment(speakerId: id, startMs: $0.0, endMs: $0.1) } }
            .sorted { $0.startMs < $1.startMs }
        var embeddings: [String: SpeakerEmbedding] = [:]
        for (id, voice) in voices { embeddings[id] = embedding(voice: voice, degrees: degrees[id] ?? 0) }
        return MacParakeetDiarizationResult(
            segments: segments,
            speakerCount: ids.count,
            speakers: ids.map { SpeakerInfo(id: $0, label: $0) },
            speakerEmbeddings: embeddings,
            speechMsBySpeaker: Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, spans[id]!.reduce(0) { $0 + $1.1 - $1.0 })
            })
        )
    }

    private func embedding(voice: Int, degrees: Double) -> SpeakerEmbedding {
        let radians = degrees * Double.pi / 180
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[voice] = Float(cos(radians))
        values[SpeakerEmbedding.dimension - 1 - voice] = Float(sin(radians))
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }
}

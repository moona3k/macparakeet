import XCTest
import FluidAudio
@testable import MacParakeetCore

/// Covers what the diarization adapter now carries out of FluidAudio:
/// per-speaker embeddings, rekeyed onto our stable ids, plus speech durations.
final class DiarizationServiceEmbeddingTests: XCTestCase {

    private static let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    private func unitVector(_ index: Int, scale: Float = 1) -> [Float] {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[index] = scale
        return values
    }

    // MARK: Rekeying

    /// FluidAudio numbers clusters by cluster index; we renumber by who speaks
    /// first. Both use the "S1", "S2" shape, so carrying the database keys over
    /// untouched would attach one speaker's voice to another's label without
    /// any type error to catch it.
    func testEmbeddingsFollowTheChronologicalRemapNotTheFluidAudioKeys() throws {
        let embeddings = DiarizationService.speakerEmbeddings(
            from: ["S1": unitVector(0), "S2": unitVector(1)],
            idMapping: ["S2": "S1", "S1": "S2"],
            identity: Self.identity
        )

        XCTAssertEqual(embeddings.count, 2)
        XCTAssertEqual(try XCTUnwrap(embeddings["S1"]).vector, unitVector(1))
        XCTAssertEqual(try XCTUnwrap(embeddings["S2"]).vector, unitVector(0))
    }

    func testEmbeddingsAreNormalizedOnTheWayOut() throws {
        let embeddings = DiarizationService.speakerEmbeddings(
            from: ["S1": unitVector(0, scale: 0.42)],
            idMapping: ["S1": "S1"],
            identity: Self.identity
        )

        XCTAssertEqual(try XCTUnwrap(embeddings["S1"]).vector, unitVector(0))
    }

    func testUnmappedSpeakersAreDropped() {
        let embeddings = DiarizationService.speakerEmbeddings(
            from: ["S1": unitVector(0), "S9": unitVector(1)],
            idMapping: ["S1": "S1"],
            identity: Self.identity
        )

        XCTAssertEqual(Set(embeddings.keys), ["S1"])
    }

    func testZeroVectorSpeakerIsDroppedFromTheDictionary() {
        let embeddings = DiarizationService.speakerEmbeddings(
            from: [
                "S1": [Float](repeating: 0, count: SpeakerEmbedding.dimension),
                "S2": unitVector(1),
            ],
            idMapping: ["S1": "S1", "S2": "S2"],
            identity: Self.identity
        )

        XCTAssertEqual(Set(embeddings.keys), ["S2"])
    }

    func testMissingSpeakerDatabaseYieldsNoEmbeddings() {
        XCTAssertTrue(
            DiarizationService.speakerEmbeddings(
                from: nil,
                idMapping: ["S1": "S1"],
                identity: Self.identity
            ).isEmpty
        )
    }

    // MARK: End to end through the service

    func testDiarizeSurfacesEmbeddingsAndDurationsWithoutChangingLabels() async throws {
        let service = makeService(
            result: DiarizationResult(
                segments: [
                    // FluidAudio's "S2" speaks first, so it becomes our "S1".
                    segment(speakerId: "S2", from: 0, to: 4),
                    segment(speakerId: "S1", from: 4, to: 10),
                    segment(speakerId: "S2", from: 10, to: 12),
                ],
                speakerDatabase: ["S1": unitVector(0), "S2": unitVector(1, scale: 0.6)]
            )
        )

        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/meeting.wav"))

        XCTAssertEqual(result.speakers.map(\.id), ["S1", "S2"])
        XCTAssertEqual(result.speakers.map(\.label), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(result.speakerCount, 2)

        // 4 s + 2 s for the first speaker, 6 s for the second.
        XCTAssertEqual(result.speechMsBySpeaker, ["S1": 6000, "S2": 6000])

        XCTAssertEqual(try XCTUnwrap(result.speakerEmbeddings["S1"]).vector, unitVector(1))
        XCTAssertEqual(try XCTUnwrap(result.speakerEmbeddings["S2"]).vector, unitVector(0))
    }

    func testDiarizeWithoutEmbeddingsStillReturnsSegments() async throws {
        let service = makeService(
            result: DiarizationResult(segments: [segment(speakerId: "S1", from: 0, to: 3)])
        )

        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/meeting.wav"))

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.speechMsBySpeaker, ["S1": 3000])
        XCTAssertTrue(result.speakerEmbeddings.isEmpty)
    }

    /// The gates are in seconds and everything else here is in milliseconds, so
    /// the conversion lives in one tested place rather than at each call site.
    func testSpeechSecondsConvertsFromMilliseconds() {
        let result = MacParakeetDiarizationResult(
            segments: [],
            speakerCount: 1,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")],
            speechMsBySpeaker: ["S1": 12_500]
        )

        XCTAssertEqual(result.speechSeconds(forSpeaker: "S1"), 12.5, accuracy: 1e-9)
        XCTAssertEqual(result.speechSeconds(forSpeaker: "S2"), 0)
    }

    // MARK: Model identity

    func testAggregationProfileChangesWithClusteringConfiguration() {
        let base = DiarizationService.highAccuracyConfig
        var altered = base
        altered.clustering.threshold += 0.1

        let baseIdentity = DiarizationService.modelIdentity(for: base)
        let alteredIdentity = DiarizationService.modelIdentity(for: altered)

        XCTAssertEqual(baseIdentity.embeddingModelId, alteredIdentity.embeddingModelId)
        XCTAssertNotEqual(baseIdentity.aggregationProfileId, alteredIdentity.aggregationProfileId)
    }

    func testAggregationProfileChangesWithVBxRefinement() {
        let base = DiarizationService.highAccuracyConfig
        var altered = base
        altered.vbx.maxIterations += 1

        XCTAssertNotEqual(
            DiarizationService.modelIdentity(for: base).aggregationProfileId,
            DiarizationService.modelIdentity(for: altered).aggregationProfileId
        )
    }

    /// A per-run speaker count is a caller hint, not a different representation:
    /// folding it into the identity would make a profile enrolled under a hint
    /// incomparable with the same voice heard without one.
    func testAggregationProfileIgnoresPerRunSpeakerConstraints() {
        let base = DiarizationService.highAccuracyConfig
        let constrained = DiarizationService.applying(.exact(3), to: base)

        XCTAssertEqual(
            DiarizationService.modelIdentity(for: base),
            DiarizationService.modelIdentity(for: constrained)
        )
    }

    func testAggregationProfileIsStableAcrossCalls() {
        XCTAssertEqual(
            DiarizationService.modelIdentity(for: DiarizationService.highAccuracyConfig),
            DiarizationService.modelIdentity(for: DiarizationService.highAccuracyConfig)
        )
    }

    // MARK: Helpers

    private func segment(speakerId: String, from start: Float, to end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [Float](repeating: 0, count: SpeakerEmbedding.dimension),
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1
        )
    }

    private func makeService(result: DiarizationResult) -> DiarizationService {
        let manager = StubOfflineDiarizerManager(result: result)
        return DiarizationService(
            loadManagerFactory: { _ in { _ in manager } },
            modelsDirectory: FileManager.default.temporaryDirectory,
            explicitConstraint: nil,
            inferenceGate: ANEInferenceGate(serializationRequired: false),
            modelIdentity: Self.identity
        )
    }
}

private final class StubOfflineDiarizerManager: OfflineDiarizerManaging, @unchecked Sendable {
    private let result: DiarizationResult

    init(result: DiarizationResult) {
        self.result = result
    }

    func process(audioURL: URL) async throws -> DiarizationResult {
        result
    }
}

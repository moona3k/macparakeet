import XCTest
@testable import MacParakeetCore

final class SpeakerEmbeddingTests: XCTestCase {

    // MARK: Fixtures

    /// Orthonormal basis vectors from a fixed seed, so distances are exact
    /// rather than approximate: a voice is `e_i`, and a noisy observation at
    /// angle theta is `cos(theta) * e_i + sin(theta) * e_j`, whose cosine
    /// distance to `e_i` is exactly `1 - cos(theta)`.
    private static func basisVector(_ index: Int) -> [Float] {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[index] = 1
        return values
    }

    private static func observation(of speaker: Int, towards other: Int, degrees: Double) -> [Float] {
        let radians = degrees * .pi / 180
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[speaker] = Float(cos(radians))
        values[other] = Float(sin(radians))
        return values
    }

    private static let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    private func embedding(
        _ raw: [Float],
        identity: SpeakerModelIdentity = SpeakerEmbeddingTests.identity
    ) -> SpeakerEmbedding {
        guard let embedding = SpeakerEmbedding(rawVector: raw, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }

    // MARK: Normalization

    func testInitNormalizesToUnitLength() {
        let scaled = Self.observation(of: 0, towards: 1, degrees: 25).map { $0 * 0.83 }
        let embedding = embedding(scaled)

        let norm = embedding.vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 1e-5)
    }

    /// The regression that matters: an un-normalized pair must produce the same
    /// decision as a normalized one, *and* the bare dot product must be shown to
    /// differ — otherwise this test would still pass if normalization were
    /// removed.
    func testScalingDoesNotChangeDistanceButWouldChangeABareDotProduct() throws {
        let rawA = Self.basisVector(0).map { $0 * 0.85 }
        let rawB = Self.observation(of: 0, towards: 1, degrees: 25).map { $0 * 0.85 }

        let distance = try XCTUnwrap(embedding(rawA).cosineDistance(to: embedding(rawB)))
        let expected = 1 - cos(25 * Double.pi / 180)
        XCTAssertEqual(distance, expected, accuracy: 1e-5)

        // What the July plan's "embeddings are already normalized" shortcut
        // would have computed instead.
        let bareDot = zip(rawA, rawB).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let bareDistance = 1 - Double(bareDot)
        XCTAssertGreaterThan(bareDistance - distance, 0.15)
    }

    func testDistanceToOwnScaledCopyIsZero() throws {
        let raw = Self.observation(of: 3, towards: 7, degrees: 40)
        let distance = try XCTUnwrap(
            embedding(raw).cosineDistance(to: embedding(raw.map { $0 * 0.5 }))
        )
        XCTAssertEqual(distance, 0, accuracy: 1e-6)
    }

    func testDistanceMatchesTheFixtureAngle() throws {
        for degrees in [0.0, 25.0, 41.4, 60.0] {
            let distance = try XCTUnwrap(
                embedding(Self.basisVector(0))
                    .cosineDistance(to: embedding(Self.observation(of: 0, towards: 1, degrees: degrees)))
            )
            XCTAssertEqual(distance, 1 - cos(degrees * .pi / 180), accuracy: 1e-5)
        }
    }

    // MARK: Rejected input

    func testRejectsZeroVector() {
        // FluidAudio emits this when a cluster's responsibility denominator is zero.
        let zeros = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        XCTAssertNil(SpeakerEmbedding(rawVector: zeros, identity: Self.identity))
    }

    func testRejectsVectorBelowMinimumNorm() {
        let tiny = Self.basisVector(0).map { $0 * 1e-9 }
        XCTAssertNil(SpeakerEmbedding(rawVector: tiny, identity: Self.identity))
    }

    func testRejectsNonFiniteValues() {
        var withNaN = Self.basisVector(0)
        withNaN[5] = .nan
        XCTAssertNil(SpeakerEmbedding(rawVector: withNaN, identity: Self.identity))

        var withInfinity = Self.basisVector(0)
        withInfinity[5] = .infinity
        XCTAssertNil(SpeakerEmbedding(rawVector: withInfinity, identity: Self.identity))
    }

    func testRejectsWrongDimension() {
        XCTAssertNil(SpeakerEmbedding(rawVector: [1, 0, 0], identity: Self.identity))
        XCTAssertNil(
            SpeakerEmbedding(
                rawVector: [Float](repeating: 0.1, count: SpeakerEmbedding.dimension + 1),
                identity: Self.identity
            )
        )
    }

    // MARK: Storage round trip

    func testDataRoundTripIsBitExact() throws {
        let original = embedding(Self.observation(of: 2, towards: 9, degrees: 33))
        let data = original.data
        XCTAssertEqual(data.count, SpeakerEmbedding.byteCount)
        XCTAssertEqual(data.count, 1024)

        let restored = try XCTUnwrap(SpeakerEmbedding(data: data, identity: Self.identity))
        XCTAssertEqual(restored.vector, original.vector)
        XCTAssertEqual(restored, original)
    }

    func testRejectsDataOfWrongLength() {
        let short = Data(repeating: 0, count: SpeakerEmbedding.byteCount - 4)
        XCTAssertNil(SpeakerEmbedding(data: short, identity: Self.identity))
    }

    func testRejectsDataThatIsNotUnitLength() {
        // A vector that never went through `init?(rawVector:)`, so the stored
        // invariant does not hold: reject rather than silently rescale.
        var raw = Data()
        for _ in 0..<SpeakerEmbedding.dimension {
            withUnsafeBytes(of: Float(0.5).bitPattern.littleEndian) { raw.append(contentsOf: $0) }
        }
        XCTAssertNil(SpeakerEmbedding(data: raw, identity: Self.identity))
    }

    // MARK: Model identity

    func testDistanceIsUnavailableAcrossEmbeddingModels() {
        let other = SpeakerModelIdentity(embeddingModelId: "other-model", aggregationProfileId: "test-aggregation")
        let lhs = embedding(Self.basisVector(0))
        let rhs = embedding(Self.basisVector(0), identity: other)
        XCTAssertNil(lhs.cosineDistance(to: rhs))
    }

    func testDistanceIsAvailableAcrossAggregationProfiles() throws {
        let other = SpeakerModelIdentity(embeddingModelId: "test-model", aggregationProfileId: "other-aggregation")
        let lhs = embedding(Self.basisVector(0))
        let rhs = embedding(Self.basisVector(0), identity: other)
        XCTAssertEqual(try XCTUnwrap(lhs.cosineDistance(to: rhs)), 0, accuracy: 1e-6)
    }
}

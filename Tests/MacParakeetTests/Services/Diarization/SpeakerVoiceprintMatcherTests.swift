import XCTest
@testable import MacParakeetCore

/// Fixtures are exact geometry, not random vectors: a voice is a basis vector,
/// and an observation at angle theta has cosine distance exactly `1 - cos
/// theta`. Every threshold below therefore reads in degrees, and a failure says
/// which angle moved rather than which seed.
final class SpeakerVoiceprintMatcherTests: XCTestCase {

    private let policy = SpeakerMatchPolicy.v1

    // 14.1 degrees -> 0.030, 25 -> 0.094, 41.4 -> 0.250 (exactly tau),
    // 45 -> 0.293, 60 -> 0.500.
    private enum Angle {
        static let veryClose = 14.1
        static let close = 25.0
        static let atTau = 41.4
        static let pastTau = 45.0
        static let far = 60.0
    }

    // MARK: Acceptance

    func testSuggestsTheOnlyEnrolledVoiceWhenItIsCloseEnough() {
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [cluster("S1", voice: 0, degrees: Angle.close)],
            profiles: [profile("Sarah", voice: 0)],
            policy: policy
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.speakerId, "S1")
        XCTAssertEqual(suggestions.first?.displayName, "Sarah")
        XCTAssertEqual(try XCTUnwrap(suggestions.first?.distance), 0.094, accuracy: 0.002)
        // Nothing to be separated from, so no runner-up is recorded.
        XCTAssertNil(suggestions.first?.runnerUpDistance)
    }

    func testRejectsAVoiceBeyondTau() {
        XCTAssertTrue(
            SpeakerVoiceprintMatcher.match(
                clusters: [cluster("S1", voice: 0, degrees: Angle.pastTau)],
                profiles: [profile("Sarah", voice: 0)],
                policy: policy
            ).isEmpty
        )
    }

    func testAcceptsExactlyAtTau() {
        XCTAssertEqual(
            SpeakerVoiceprintMatcher.match(
                clusters: [cluster("S1", voice: 0, degrees: Angle.atTau)],
                profiles: [profile("Sarah", voice: 0)],
                policy: policy
            ).count,
            1
        )
    }

    // MARK: Singleton sides

    /// The case the first review caught: with one profile and one cluster there
    /// is no runner-up, so a naive margin check would reject the very first
    /// enrolled voice forever.
    func testMarginIsVacuouslySatisfiedWhenEitherSideHasOneCandidate() {
        XCTAssertEqual(
            SpeakerVoiceprintMatcher.match(
                clusters: [cluster("S1", voice: 0, degrees: Angle.veryClose)],
                profiles: [profile("Sarah", voice: 0)],
                policy: policy
            ).count,
            1
        )

        // One profile, several clusters: the profile side has no runner-up
        // among profiles, and the far cluster does not compete.
        XCTAssertEqual(
            SpeakerVoiceprintMatcher.match(
                clusters: [
                    cluster("S1", voice: 0, degrees: Angle.veryClose),
                    cluster("S2", voice: 5, degrees: 0),
                ],
                profiles: [profile("Sarah", voice: 0)],
                policy: policy
            ).map(\.speakerId),
            ["S1"]
        )
    }

    // MARK: Margins

    func testRejectsWhenTwoProfilesAreTooCloseTogether() {
        // The cluster sits 14.1 degrees off Sarah and 10.9 off Sasha: 0.030
        // against 0.018. Both clear tau, they are 0.012 apart, and naming
        // either one would be a coin toss.
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [cluster("S1", voice: 0, degrees: Angle.veryClose)],
            profiles: [
                profile("Sarah", voice: 0),
                profile("Sasha", voice: 0, degrees: Angle.close),
            ],
            policy: policy
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    /// The two-sided rule. The diarizer over-splits, so one person often yields
    /// two clusters; a cluster-side margin alone would let both claim the same
    /// profile and put two "Sarah"s in one transcript.
    func testRejectsWhenTwoClustersCompeteForTheSameProfile() {
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [
                cluster("S1", voice: 0, degrees: Angle.veryClose),
                cluster("S2", voice: 0, degrees: Angle.close),
            ],
            profiles: [profile("Sarah", voice: 0)],
            policy: policy
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testAcceptsWhenTheCompetingClusterIsClearlyFurther() {
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [
                cluster("S1", voice: 0, degrees: Angle.veryClose),
                cluster("S2", voice: 0, degrees: Angle.far),
            ],
            profiles: [profile("Sarah", voice: 0)],
            policy: policy
        )
        XCTAssertEqual(suggestions.map(\.speakerId), ["S1"])
        XCTAssertEqual(try XCTUnwrap(suggestions.first?.runnerUpDistance), 0.5, accuracy: 0.002)
    }

    func testExactTieSuggestsNobody() {
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [cluster("S1", voice: 0, degrees: Angle.close)],
            profiles: [
                profile("Sarah", voice: 0),
                profile("Sasha", voice: 0),
            ],
            policy: policy
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    /// The tie rule must not depend on how the margin is configured: at
    /// `margin: 0` the difference check passes and position alone would decide.
    func testExactTieSuggestsNobodyEvenWithoutAMargin() {
        let zeroMargin = SpeakerMatchPolicy(
            tau: policy.tau,
            margin: 0,
            minSpeechSecondsToMatch: policy.minSpeechSecondsToMatch,
            minSpeechSecondsToEnroll: policy.minSpeechSecondsToEnroll,
            maxReferencesPerProfile: policy.maxReferencesPerProfile,
            crossAggregationPenalty: policy.crossAggregationPenalty,
            pollutionGuardDistance: policy.pollutionGuardDistance
        )

        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [cluster("S1", voice: 0, degrees: Angle.close)],
            profiles: [profile("Sarah", voice: 0), profile("Sasha", voice: 0)],
            policy: zeroMargin
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    /// A negative cap reaches `prefix`, whose precondition would bring matching
    /// down; the policy clamps it instead.
    func testANegativeReferenceCapIsClampedRatherThanFatal() {
        let negative = SpeakerMatchPolicy(
            tau: policy.tau,
            margin: policy.margin,
            minSpeechSecondsToMatch: policy.minSpeechSecondsToMatch,
            minSpeechSecondsToEnroll: policy.minSpeechSecondsToEnroll,
            maxReferencesPerProfile: -3,
            crossAggregationPenalty: policy.crossAggregationPenalty,
            pollutionGuardDistance: policy.pollutionGuardDistance
        )
        XCTAssertEqual(negative.maxReferencesPerProfile, 0)

        // No references are scored, so nothing is proposed — and nothing traps.
        XCTAssertTrue(
            SpeakerVoiceprintMatcher.match(
                clusters: [cluster("S1", voice: 0, degrees: 0)],
                profiles: [profile("Sarah", voice: 0)],
                policy: negative
            ).isEmpty
        )
    }

    // MARK: Injectivity

    func testOneProfileIsNeverSuggestedForTwoSpeakers() {
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [
                cluster("S1", voice: 0, degrees: Angle.veryClose),
                cluster("S2", voice: 0, degrees: Angle.far),
                cluster("S3", voice: 1, degrees: Angle.veryClose),
            ],
            profiles: [profile("Sarah", voice: 0), profile("Dan", voice: 1)],
            policy: policy
        )

        XCTAssertEqual(Set(suggestions.map(\.profileId)).count, suggestions.count)
        XCTAssertEqual(Set(suggestions.map(\.speakerId)), ["S1", "S3"])
    }

    func testTwoDistinctVoicesMatchTheirOwnProfiles() {
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [
                cluster("S1", voice: 0, degrees: Angle.close),
                cluster("S2", voice: 1, degrees: Angle.close),
            ],
            profiles: [profile("Sarah", voice: 0), profile("Dan", voice: 1)],
            policy: policy
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: suggestions.map { ($0.speakerId, $0.displayName) }),
            ["S1": "Sarah", "S2": "Dan"]
        )
    }

    // MARK: Duration gates

    func testClustersBelowTheSpeechGateAreNeverScored() {
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [cluster("S1", voice: 0, degrees: 0, speechSeconds: 2.5)],
            profiles: [profile("Sarah", voice: 0)],
            policy: policy
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testAClusterAboveTheMatchGateButBelowTheEnrollGateStillMatches() {
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [cluster("S1", voice: 0, degrees: 0, speechSeconds: 12)],
            profiles: [profile("Sarah", voice: 0)],
            policy: policy
        )
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertLessThan(12, policy.minSpeechSecondsToEnroll)
    }

    // MARK: Model identity

    func testReferencesFromAnotherEmbeddingModelAreIgnored() {
        let otherModel = SpeakerModelIdentity(
            embeddingModelId: "other-model",
            aggregationProfileId: Self.identity.aggregationProfileId
        )
        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [cluster("S1", voice: 0, degrees: 0)],
            profiles: [profile("Sarah", voice: 0, identity: otherModel)],
            policy: policy
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testADifferentAggregationProfileTightensTheThreshold() {
        let otherAggregation = SpeakerModelIdentity(
            embeddingModelId: Self.identity.embeddingModelId,
            aggregationProfileId: "other-aggregation"
        )
        // 0.217 clears tau (0.25) but not tau minus the 0.05 penalty (0.20).
        let borderline = 38.5

        XCTAssertEqual(
            SpeakerVoiceprintMatcher.match(
                clusters: [cluster("S1", voice: 0, degrees: borderline)],
                profiles: [profile("Sarah", voice: 0)],
                policy: policy
            ).count,
            1
        )
        XCTAssertTrue(
            SpeakerVoiceprintMatcher.match(
                clusters: [cluster("S1", voice: 0, degrees: borderline)],
                profiles: [profile("Sarah", voice: 0, identity: otherAggregation)],
                policy: policy
            ).isEmpty
        )
    }

    /// A profile that straddles a FluidAudio upgrade holds one exemplar from
    /// each aggregation. The penalty must follow the reference that actually
    /// won, otherwise the presence of a current exemplar would buy full trust
    /// for a decision an older one made.
    func testThePenaltyFollowsTheWinningReferenceNotTheProfile() {
        let old = SpeakerModelIdentity(
            embeddingModelId: Self.identity.embeddingModelId,
            aggregationProfileId: "pre-upgrade"
        )
        let borderline = 38.5  // 0.217: clears tau, not tau minus the penalty.

        let straddling = SpeakerProfileCandidate(
            profileId: UUID(),
            displayName: "Sarah",
            references: [
                // Closest, but from the old aggregation.
                reference(voice: 0, degrees: 0, identity: old),
                // Current aggregation, but far away.
                reference(voice: 7, degrees: 0),
            ]
        )

        let suggestions = SpeakerVoiceprintMatcher.match(
            clusters: [cluster("S1", voice: 0, degrees: borderline)],
            profiles: [straddling],
            policy: policy
        )
        XCTAssertTrue(suggestions.isEmpty)

        let winning = SpeakerVoiceprintMatcher.bestReference(
            from: cluster("S1", voice: 0, degrees: borderline),
            to: straddling,
            policy: policy
        )
        XCTAssertFalse(try XCTUnwrap(winning).sameAggregation)
    }

    // MARK: Scoring across references

    func testProfileDistanceIsTheClosestReferenceNotTheAverage() {
        let candidate = SpeakerProfileCandidate(
            profileId: UUID(),
            displayName: "Sarah",
            references: [
                reference(voice: 0, degrees: Angle.far),
                reference(voice: 0, degrees: Angle.close),
            ]
        )
        let distance = SpeakerVoiceprintMatcher.distance(
            from: cluster("S1", voice: 0, degrees: 0),
            to: candidate,
            policy: policy
        )
        XCTAssertEqual(try XCTUnwrap(distance), 0.094, accuracy: 0.002)
    }

    func testOnlyTheFirstReferencesUpToTheCapAreScored() {
        var references = (0..<policy.maxReferencesPerProfile).map { _ in
            reference(voice: 0, degrees: Angle.far)
        }
        references.append(reference(voice: 0, degrees: 0))

        let candidate = SpeakerProfileCandidate(
            profileId: UUID(), displayName: "Sarah", references: references
        )
        let distance = SpeakerVoiceprintMatcher.distance(
            from: cluster("S1", voice: 0, degrees: 0),
            to: candidate,
            policy: policy
        )
        // The perfect reference sits past the cap and never gets scored.
        XCTAssertEqual(try XCTUnwrap(distance), 0.5, accuracy: 0.002)
    }

    func testNoProfilesOrNoClustersYieldsNothing() {
        XCTAssertTrue(
            SpeakerVoiceprintMatcher.match(
                clusters: [cluster("S1", voice: 0, degrees: 0)], profiles: [], policy: policy
            ).isEmpty
        )
        XCTAssertTrue(
            SpeakerVoiceprintMatcher.match(
                clusters: [], profiles: [profile("Sarah", voice: 0)], policy: policy
            ).isEmpty
        )
    }

    func testProfileWithNoReferencesIsSkipped() {
        let empty = SpeakerProfileCandidate(profileId: UUID(), displayName: "Sarah", references: [])
        XCTAssertTrue(
            SpeakerVoiceprintMatcher.match(
                clusters: [cluster("S1", voice: 0, degrees: 0)], profiles: [empty], policy: policy
            ).isEmpty
        )
    }

    // MARK: Fixtures

    private static let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    /// `cos(theta) * e_voice + sin(theta) * e_offAxis`, whose distance to
    /// `e_voice` is exactly `1 - cos(theta)`.
    private func embedding(
        voice: Int,
        degrees: Double,
        identity: SpeakerModelIdentity = SpeakerVoiceprintMatcherTests.identity
    ) -> SpeakerEmbedding {
        let radians = degrees * Double.pi / 180
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[voice] = Float(cos(radians))
        values[SpeakerEmbedding.dimension - 1 - voice] = Float(sin(radians))
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }

    private func cluster(
        _ speakerId: String,
        voice: Int,
        degrees: Double,
        speechSeconds: Double = 30
    ) -> SpeakerClusterObservation {
        SpeakerClusterObservation(
            speakerId: speakerId,
            embedding: embedding(voice: voice, degrees: degrees),
            speechSeconds: speechSeconds,
            captureDomain: .system
        )
    }

    private func reference(
        voice: Int,
        degrees: Double,
        identity: SpeakerModelIdentity = SpeakerVoiceprintMatcherTests.identity
    ) -> SpeakerProfileCandidate.Reference {
        SpeakerProfileCandidate.Reference(
            embedding: embedding(voice: voice, degrees: degrees, identity: identity),
            captureDomain: .system
        )
    }

    private func profile(
        _ name: String,
        voice: Int,
        degrees: Double = 0,
        identity: SpeakerModelIdentity = SpeakerVoiceprintMatcherTests.identity
    ) -> SpeakerProfileCandidate {
        SpeakerProfileCandidate(
            profileId: UUID(),
            displayName: name,
            references: [reference(voice: voice, degrees: degrees, identity: identity)]
        )
    }
}

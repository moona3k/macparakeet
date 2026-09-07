import XCTest
@testable import MacParakeetCore

final class MeetingSpeakerPriorTests: XCTestCase {

    func testNoAttendeeCountIsUnconstrained() {
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(remoteAttendeeCount: nil),
            .unconstrained(reason: .noAttendeeCount)
        )
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(remoteAttendeeCount: 0),
            .unconstrained(reason: .noAttendeeCount)
        )
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(from: nil),
            .unconstrained(reason: .noAttendeeCount)
        )
        XCTAssertNil(MeetingSpeakerPrior.derive(remoteAttendeeCount: nil).speakerConstraint)
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(remoteAttendeeCount: nil).diagnosticsLabel,
            "unconstrained_no_attendee_count"
        )
    }

    func testSingleRemoteAttendeeStillRunsClusteringWithACapOfTwo() {
        let prior = MeetingSpeakerPrior.derive(remoteAttendeeCount: 1)

        XCTAssertEqual(prior, .bounds(min: 1, max: 2))
        XCTAssertEqual(prior.speakerConstraint, .range(min: 1, max: 2))
        XCTAssertEqual(prior.diagnosticsLabel, "bounds_1_2")
    }

    func testTwoAttendeesYieldBoundsOneToThree() {
        let prior = MeetingSpeakerPrior.derive(remoteAttendeeCount: 2)

        XCTAssertEqual(prior, .bounds(min: 1, max: 3))
        XCTAssertEqual(prior.speakerConstraint, .range(min: 1, max: 3))
        XCTAssertEqual(prior.diagnosticsLabel, "bounds_1_3")
    }

    func testFiveAttendeesYieldBoundsOneToSix() {
        let prior = MeetingSpeakerPrior.derive(remoteAttendeeCount: 5)

        XCTAssertEqual(prior, .bounds(min: 1, max: 6))
        XCTAssertEqual(prior.speakerConstraint, .range(min: 1, max: 6))
    }

    func testMinimumIsAlwaysOneAndBoundsAreNeverExact() {
        for count in 1...MeetingSpeakerPrior.maxAttendeesForBounds {
            guard case .bounds(let min, let max) = MeetingSpeakerPrior.derive(remoteAttendeeCount: count) else {
                return XCTFail("expected bounds for \(count) attendees")
            }
            XCTAssertEqual(min, 1, "the prior must never force clusters upward")
            XCTAssertEqual(max, count + 1)
            XCTAssertLessThan(min, max)
        }
    }

    func testLargeInvitesFallBackToUnconstrained() {
        let prior = MeetingSpeakerPrior.derive(
            remoteAttendeeCount: MeetingSpeakerPrior.maxAttendeesForBounds + 1
        )

        XCTAssertEqual(prior, .unconstrained(reason: .largeAttendeeCount))
        XCTAssertNil(prior.speakerConstraint)
        XCTAssertEqual(prior.diagnosticsLabel, "unconstrained_large_attendee_count")
    }

    func testSnapshotAttendeesAreDedupedByEmailThenName() {
        let snapshot = makeSnapshot(attendees: [
            MeetingCalendarPerson(name: "Ada", email: "ada@example.com"),
            MeetingCalendarPerson(name: "Ada Lovelace", email: "ADA@example.com "),
            MeetingCalendarPerson(name: "Grace", email: nil),
            MeetingCalendarPerson(name: " grace ", email: nil),
            MeetingCalendarPerson(name: nil, email: nil),
        ])

        XCTAssertEqual(MeetingSpeakerPrior.remoteAttendeeCount(in: snapshot), 3)
        XCTAssertEqual(MeetingSpeakerPrior.derive(from: snapshot), .bounds(min: 1, max: 4))
    }

    func testDeclinedAttendeesAndResourcesAreNotCounted() {
        let snapshot = makeSnapshot(attendees: [
            MeetingCalendarPerson(name: "Ada", email: "ada@example.com", status: "accepted", kind: "person"),
            MeetingCalendarPerson(name: "Grace", email: "grace@example.com", status: "declined", kind: "person"),
            MeetingCalendarPerson(name: "Linus", email: "linus@example.com", status: "tentative", kind: "person"),
            MeetingCalendarPerson(name: "Ken", email: "ken@example.com", status: nil, kind: nil),
            MeetingCalendarPerson(name: "Room 4B", email: "room4b@example.com", status: "accepted", kind: "room"),
            MeetingCalendarPerson(name: "Projector", email: "projector@example.com", status: "accepted", kind: "resource"),
            MeetingCalendarPerson(name: "Platform Team", email: "platform@example.com", status: "accepted", kind: "group"),
        ])

        XCTAssertEqual(MeetingSpeakerPrior.remoteAttendeeCount(in: snapshot), 3)
        XCTAssertEqual(MeetingSpeakerPrior.derive(from: snapshot), .bounds(min: 1, max: 4))
    }

    func testNameOnlyAndEmailEntriesForTheSamePersonCountSeparately() {
        // Documented fallback-key behavior: one key per entry, no cross-field reconciliation.
        let snapshot = makeSnapshot(attendees: [
            MeetingCalendarPerson(name: "Ada", email: "ada@example.com"),
            MeetingCalendarPerson(name: "Ada", email: nil),
        ])

        XCTAssertEqual(MeetingSpeakerPrior.remoteAttendeeCount(in: snapshot), 2)
    }

    func testSnapshotWithoutCountableAttendeesIsUnconstrained() {
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(from: makeSnapshot(attendees: [])),
            .unconstrained(reason: .noAttendeeCount)
        )
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(from: makeSnapshot(attendees: [
                MeetingCalendarPerson(name: "Grace", email: "grace@example.com", status: "declined"),
            ])),
            .unconstrained(reason: .noAttendeeCount)
        )
    }

    func testPolicyResolvesExplicitConstraintOverPrior() {
        let prior = MeetingSpeakerPrior.bounds(min: 1, max: 2)

        let withExplicit = MeetingSpeakerPolicy.resolve(prior: prior, explicitConstraint: .exact(3))
        XCTAssertEqual(withExplicit, .explicitConstraint)
        XCTAssertNil(withExplicit.speakerConstraintHint)
        XCTAssertEqual(withExplicit.diagnosticsLabel, "explicit_cli")

        let withoutExplicit = MeetingSpeakerPolicy.resolve(prior: prior, explicitConstraint: nil)
        XCTAssertEqual(withoutExplicit, .prior(prior))
        XCTAssertEqual(withoutExplicit.speakerConstraintHint, .range(min: 1, max: 2))
        XCTAssertEqual(withoutExplicit.diagnosticsLabel, "bounds_1_2")

        let unconstrained = MeetingSpeakerPolicy.resolve(
            prior: .unconstrained(reason: .noAttendeeCount),
            explicitConstraint: nil
        )
        XCTAssertNil(unconstrained.speakerConstraintHint)
        XCTAssertEqual(unconstrained.diagnosticsLabel, "unconstrained_no_attendee_count")
    }

    func testLegacySnapshotWithoutStatusOrKindStillDecodesAndCounts() throws {
        let legacy = Data(#"{"name":"Ada","email":"ada@example.com"}"#.utf8)
        let person = try JSONDecoder().decode(MeetingCalendarPerson.self, from: legacy)

        XCTAssertNil(person.status)
        XCTAssertNil(person.kind)
        XCTAssertTrue(MeetingSpeakerPrior.isCountable(person))
    }

    private func makeSnapshot(attendees: [MeetingCalendarPerson]) -> MeetingCalendarSnapshot {
        MeetingCalendarSnapshot(
            confidence: .confirmed,
            eventIdentifier: "event",
            title: "Sync",
            scheduledStartAt: Date(timeIntervalSince1970: 1_700_000_000),
            scheduledEndAt: Date(timeIntervalSince1970: 1_700_003_600),
            attendees: attendees
        )
    }
}

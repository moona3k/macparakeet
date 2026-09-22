import XCTest
@testable import MacParakeetCore

final class MeetingMonitorTests: XCTestCase {

    // MARK: - Helpers

    private func event(
        id: String = "evt-1",
        title: String = "Standup",
        startsIn seconds: TimeInterval = 0,
        from referenceDate: Date,
        durationMinutes: Int = 30,
        meetUrl: String? = "https://zoom.us/j/123",
        participants: [EventParticipant] = [EventParticipant(email: "alice@example.com")],
        userStatus: EventParticipant.ParticipantStatus? = .accepted,
        isAllDay: Bool = false,
        externalId: String? = nil,
        isRecurring: Bool = false
    ) -> CalendarEvent {
        let start = referenceDate.addingTimeInterval(seconds)
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return CalendarEvent(
            id: id,
            title: title,
            startTime: start,
            endTime: end,
            meetUrl: meetUrl,
            participants: participants,
            isAllDay: isAllDay,
            userStatus: userStatus,
            externalId: externalId,
            isRecurring: isRecurring
        )
    }

    private func config(
        mode: CalendarAutoStartMode = .notify,
        reminderMinutes: Int = 5,
        triggerFilter: MeetingTriggerFilter = .withLink,
        skippedOccurrences: Set<String> = [],
        skippedEvents: Set<String> = []
    ) -> MeetingMonitor.Config {
        MeetingMonitor.Config(
            mode: mode,
            reminderMinutes: reminderMinutes,
            countdownSeconds: 5,
            triggerFilter: triggerFilter,
            lateJoinGraceMinutes: 10,
            skippedOccurrences: skippedOccurrences,
            skippedEvents: skippedEvents
        )
    }

    private func extractIds(_ events: [MeetingMonitor.MonitorEvent]) -> [String] {
        events.map {
            switch $0 {
            case .reminderDue(let e), .autoStartDue(let e), .lateJoinAvailable(let e):
                return e.id
            }
        }
    }

    // MARK: - Mode gating

    func testOffModeProducesNoEvents() {
        let now = Date()
        let evt = event(startsIn: -5 * 60, from: now)  // exactly at reminder time
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .off),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testNotifyModeWithReminderMinutesZeroProducesNothing() {
        let now = Date()
        // reminderMinutes=0 disables reminders entirely; .notify mode also
        // gates `.autoStartDue`/`.lateJoinAvailable` off — so there is
        // nothing to emit even though the event is at T-0.
        let evt = event(startsIn: 0, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .notify, reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testNotifyModeFiresReminderButNotAutoStart() {
        let now = Date()
        // Event starts in 5 min — exactly the reminder time. .notify mode
        // should emit `.reminderDue` and *not* `.autoStartDue` (which is
        // gated off in this mode regardless of timing window).
        let evt = event(startsIn: 5 * 60, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .notify, reminderMinutes: 5),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertEqual(result.count, 1)
        if case .reminderDue(let e) = result[0] {
            XCTAssertEqual(e.id, "evt-1")
        } else {
            XCTFail("Expected .reminderDue, got \(result[0])")
        }
        XCTAssertFalse(result.contains { if case .autoStartDue = $0 { return true } else { return false } })
    }

    func testAutoStartModeFiresAutoStartWhenAtTime() {
        let now = Date()
        let evt = event(startsIn: 0, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertEqual(result.count, 1)
        if case .autoStartDue(let e) = result[0] {
            XCTAssertEqual(e.id, "evt-1")
        } else {
            XCTFail("Expected .autoStartDue, got \(result[0])")
        }
    }

    // MARK: - Reminder window

    func testReminderFiresExactlyAtTMinusReminderMinutes() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now)  // T-5min
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(reminderMinutes: 5),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertEqual(extractIds(result), ["evt-1"])
        if case .reminderDue = result[0] {} else { XCTFail("Expected .reminderDue") }
    }

    func testReminderHasNinetySecondForgivenessWindow() {
        let now = Date()
        // Event starts in 5 min - 89s; we're 89s past the ideal reminder time
        let evt = event(startsIn: 5 * 60 - 89, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(reminderMinutes: 5),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertEqual(extractIds(result), ["evt-1"], "Slow polls within 90s should still fire reminder")
    }

    func testReminderDoesNotFirePast90SecondWindow() {
        let now = Date()
        let evt = event(startsIn: 5 * 60 - 91, from: now)  // 91s past
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(reminderMinutes: 5),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testReminderSuppressedWhenAlreadyReminded() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(reminderMinutes: 5),
            activeRecording: false,
            remindedEventIds: [evt.dedupeKey],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testRescheduledEventReFiresReminder() {
        let now = Date()
        // Reminded at an earlier slot, then moved. Same id, different start
        // time → different dedupeKey → the reminder fires again.
        let rescheduled = event(id: "evt-1", startsIn: 5 * 60, from: now)
        let oldSlotKey = CalendarEvent(
            id: "evt-1",
            title: "Standup",
            startTime: now.addingTimeInterval(-3600),
            endTime: now.addingTimeInterval(-1800)
        ).dedupeKey
        let result = MeetingMonitor.evaluate(
            events: [rescheduled],
            now: now,
            config: config(reminderMinutes: 5),
            activeRecording: false,
            remindedEventIds: [oldSlotKey],
            countdownShownEventIds: []
        )
        XCTAssertEqual(extractIds(result), ["evt-1"],
                       "A reschedule to a new time must re-fire — the old slot's key must not suppress it")
    }

    func testReminderMinutesZeroDisablesReminder() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Trigger filter

    func testWithLinkFilterRejectsEventsWithoutMeetUrl() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now, meetUrl: nil)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(triggerFilter: .withLink),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testWithParticipantsFilterAcceptsAtLeastOneOther() {
        let now = Date()
        let evt = event(
            startsIn: 5 * 60,
            from: now,
            meetUrl: nil,
            participants: [EventParticipant(email: "alice@example.com")]
        )
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(triggerFilter: .withParticipants),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertEqual(extractIds(result), ["evt-1"])
    }

    func testWithParticipantsFilterRejectsSoloEvents() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now, meetUrl: nil, participants: [])
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(triggerFilter: .withParticipants),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testAllEventsFilterAcceptsBareEvent() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now, meetUrl: nil, participants: [])
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(triggerFilter: .allEvents),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertEqual(extractIds(result), ["evt-1"])
    }

    // MARK: - Universal filters (always applied regardless of trigger)

    func testAllDayEventsAreAlwaysSkipped() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now, isAllDay: true)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(triggerFilter: .allEvents),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testDeclinedEventsAreSkipped() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now, userStatus: .declined)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testSkippedOccurrenceIsNotEvaluatedButStaysACandidate() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now)
        let config = config(skippedOccurrences: [evt.dedupeKey])
        let candidates = MeetingMonitor.candidates(events: [evt], config: config)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].skipScope, .occurrence)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config,
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Auto-start window (.autoStart mode)

    func testAutoStartFiresInWindowMinusFiveSeconds() {
        let now = Date()
        let evt = event(startsIn: 5, from: now)  // 5s away — inside [-5s, +30s]
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        if case .autoStartDue = result.first {} else {
            XCTFail("Expected .autoStartDue inside [-5s, +30s] window, got \(result)")
        }
    }

    func testAutoStartDoesNotFireWhenAlreadyRecording() {
        let now = Date()
        let evt = event(startsIn: 0, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, reminderMinutes: 0),
            activeRecording: true,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertFalse(result.contains { if case .autoStartDue = $0 { return true } else { return false } })
    }

    func testAutoStartSuppressedByCountdownShownIds() {
        let now = Date()
        let evt = event(startsIn: 0, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: [evt.dedupeKey]
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - RSVP gating for auto-start (#5)

    func testAutoStartSkipsPendingInvite() {
        let now = Date()
        let evt = event(startsIn: 0, from: now, userStatus: .pending)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty,
                      "An invite the user hasn't accepted (.pending) must not auto-record")
    }

    func testAutoStartFiresForTentative() {
        let now = Date()
        let evt = event(startsIn: 0, from: now, userStatus: .tentative)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.contains { if case .autoStartDue = $0 { return true } else { return false } },
                      "A tentatively-accepted meeting is still likely-attending — auto-start should fire")
    }

    func testReminderStillFiresForPendingInvite() {
        let now = Date()
        // Reminders are lenient: a pending invite still gets a notification.
        let evt = event(startsIn: 5 * 60, from: now, userStatus: .pending)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .notify, reminderMinutes: 5),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.contains { if case .reminderDue = $0 { return true } else { return false } },
                      "Reminders should remain lenient for pending invites")
    }

    // MARK: - Late join

    func testLateJoinFiresAfter30sUntilGracePeriod() {
        let now = Date()
        // Event started 2 minutes ago — well inside [+30s, +10min] late-join window
        let evt = event(startsIn: -120, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.contains { if case .lateJoinAvailable = $0 { return true } else { return false } })
    }

    func testLateJoinDoesNotFireBeyondGracePeriod() {
        let now = Date()
        // Event started 11 minutes ago — beyond the default 10-minute grace
        let evt = event(startsIn: -11 * 60, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, reminderMinutes: 0),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Multiple events

    func testHandlesMultipleEventsIndependently() {
        let now = Date()
        let upcoming = event(id: "upcoming", startsIn: 5 * 60, from: now)
        let skipped = event(id: "skipped", startsIn: 5 * 60, from: now)
        let result = MeetingMonitor.evaluate(
            events: [upcoming, skipped],
            now: now,
            config: config(skippedOccurrences: [skipped.dedupeKey]),
            activeRecording: false,
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertEqual(extractIds(result), ["upcoming"])
    }

    func testSkippedEventKeyAppliesAfterReschedule() {
        let now = Date()
        let original = event(id: "evt-1", startsIn: 5 * 60, from: now, externalId: "ext-1")
        let moved = CalendarEvent(
            id: "evt-1",
            title: "Standup",
            startTime: now.addingTimeInterval(20 * 60),
            endTime: now.addingTimeInterval(50 * 60),
            meetUrl: "https://zoom.us/j/123",
            participants: [EventParticipant(email: "alice@example.com")],
            userStatus: .accepted,
            externalId: "ext-1"
        )
        let config = config(
            mode: .autoStart,
            reminderMinutes: 0,
            skippedEvents: [original.eventKey]
        )
        XCTAssertTrue(
            MeetingMonitor.evaluate(
                events: [moved],
                now: now.addingTimeInterval(20 * 60),
                config: config,
                activeRecording: false,
                remindedEventIds: [],
                countdownShownEventIds: []
            ).isEmpty
        )
        XCTAssertEqual(
            MeetingMonitor.candidates(events: [moved], config: config).first?.skipScope,
            .event
        )
    }

    func testIsRecurringFalseWhenExternalIdPresent() {
        let evt = event(id: "evt-1", startsIn: 0, from: Date(), externalId: "ext-1")
        XCTAssertFalse(evt.isRecurring)
        XCTAssertEqual(evt.eventKey, "ext-1")
    }

    func testEventLevelSkipWinsOverOccurrence() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now, externalId: "series", isRecurring: true)
        let config = config(
            skippedOccurrences: [evt.dedupeKey],
            skippedEvents: [evt.eventKey]
        )
        XCTAssertEqual(
            MeetingMonitor.candidates(events: [evt], config: config).first?.skipScope,
            .event
        )
    }

    func testPrunedOccurrencesKeepUnparseableAndRecentKeys() {
        let now = Date()
        let recent = "id|\(Int(now.timeIntervalSinceReferenceDate))"
        let old = "id|\(Int(now.addingTimeInterval(-20 * 24 * 60 * 60).timeIntervalSinceReferenceDate))"
        let pruned = CalendarSkip.prunedOccurrences([recent, old, "nofilter"], now: now)
        XCTAssertEqual(pruned, [recent, "nofilter"])
    }

    func testCalendarEventDecodesMissingIsRecurringAsFalse() throws {
        let json = """
        {"id":"e1","title":"Standup","startTime":0,"endTime":1800,"participants":[],"isAllDay":false,"syncedAt":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CalendarEvent.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isRecurring)
    }
}

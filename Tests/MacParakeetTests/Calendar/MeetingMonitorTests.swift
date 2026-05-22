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
        isAllDay: Bool = false
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
            userStatus: userStatus
        )
    }

    private func config(
        mode: CalendarAutoStartMode = .notify,
        reminderMinutes: Int = 5,
        triggerFilter: MeetingTriggerFilter = .withLink,
        autoStopEnabled: Bool = true
    ) -> MeetingMonitor.Config {
        MeetingMonitor.Config(
            mode: mode,
            reminderMinutes: reminderMinutes,
            countdownSeconds: 5,
            autoStopEnabled: autoStopEnabled,
            autoStopLeadSeconds: 30,
            triggerFilter: triggerFilter,
            lateJoinGraceMinutes: 10
        )
    }

    private func extractIds(_ events: [MeetingMonitor.MonitorEvent]) -> [String] {
        events.map {
            switch $0 {
            case .reminderDue(let e), .autoStartDue(let e), .lateJoinAvailable(let e), .autoStopDue(let e):
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testDismissedEventsAreSkipped() {
        let now = Date()
        let evt = event(startsIn: 5 * 60, from: now)
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(),
            activeRecording: false,
            dismissedEventIds: [evt.dedupeKey],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.contains { if case .reminderDue = $0 { return true } else { return false } },
                      "Reminders should remain lenient for pending invites")
    }

    func testAutoStopFiresForPendingInviteOnceRecording() {
        let now = Date()
        // RSVP gates auto-START only. If we're already recording a meeting
        // (regardless of RSVP), auto-stop must still fire at its end.
        let evt = CalendarEvent(
            id: "ending",
            title: "Wrap",
            startTime: now.addingTimeInterval(-1500),
            endTime: now.addingTimeInterval(20),
            meetUrl: "https://zoom.us/j/1",
            participants: [EventParticipant(email: "x@y")],
            userStatus: .pending
        )
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, autoStopEnabled: true),
            activeRecording: true,
            dismissedEventIds: [],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.contains { if case .autoStopDue = $0 { return true } else { return false } },
                      "Auto-stop is not RSVP-gated — a recording in flight must still stop at meeting end")
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
            dismissedEventIds: [],
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
            dismissedEventIds: [],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Auto-stop

    func testAutoStopFiresInLastSecondsOfMeeting() {
        let now = Date()
        // Event ends 20s after `now` (started 25 min ago, runs for 25 min) →
        // inside the [endTime - 30s, endTime] auto-stop window.
        let evt = CalendarEvent(
            id: "ending",
            title: "Wrap",
            startTime: now.addingTimeInterval(-1500),
            endTime: now.addingTimeInterval(20),
            meetUrl: "https://zoom.us/j/1",
            participants: [EventParticipant(email: "x@y")],
            userStatus: .accepted
        )
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, autoStopEnabled: true),
            activeRecording: true,
            dismissedEventIds: [],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.contains { if case .autoStopDue = $0 { return true } else { return false } })
    }

    func testAutoStopDoesNotFireWhenNotRecording() {
        let now = Date()
        let evt = CalendarEvent(
            id: "ending",
            title: "Wrap",
            startTime: now.addingTimeInterval(-1500),
            endTime: now.addingTimeInterval(20),
            meetUrl: "https://zoom.us/j/1",
            participants: [EventParticipant(email: "x@y")],
            userStatus: .accepted
        )
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart),
            activeRecording: false,
            dismissedEventIds: [],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertFalse(result.contains { if case .autoStopDue = $0 { return true } else { return false } })
    }

    func testAutoStopFiresWithinForgivenessTailPastEnd() {
        let now = Date()
        // Meeting already ended 60s ago, recording still active (we woke from
        // sleep / it ran long). Within the 5-min forgiveness tail → auto-stop
        // should still fire so the recording doesn't run forever.
        let evt = CalendarEvent(
            id: "ended",
            title: "Wrap",
            startTime: now.addingTimeInterval(-1800),
            endTime: now.addingTimeInterval(-60),
            meetUrl: "https://zoom.us/j/1",
            participants: [EventParticipant(email: "x@y")],
            userStatus: .accepted
        )
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, autoStopEnabled: true),
            activeRecording: true,
            dismissedEventIds: [],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertTrue(result.contains { if case .autoStopDue = $0 { return true } else { return false } },
                      "Auto-stop must still fire shortly after endTime (sleep / long meeting)")
    }

    func testAutoStopDoesNotFireBeyondForgivenessTail() {
        let now = Date()
        // Ended 6 minutes ago — beyond the 5-min forgiveness tail. Leave it
        // for a manual stop rather than force-stopping a long-past meeting.
        let evt = CalendarEvent(
            id: "ended",
            title: "Wrap",
            startTime: now.addingTimeInterval(-3600),
            endTime: now.addingTimeInterval(-6 * 60),
            meetUrl: "https://zoom.us/j/1",
            participants: [EventParticipant(email: "x@y")],
            userStatus: .accepted
        )
        let result = MeetingMonitor.evaluate(
            events: [evt],
            now: now,
            config: config(mode: .autoStart, autoStopEnabled: true),
            activeRecording: true,
            dismissedEventIds: [],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertFalse(result.contains { if case .autoStopDue = $0 { return true } else { return false } })
    }

    // MARK: - Multiple events

    func testHandlesMultipleEventsIndependently() {
        let now = Date()
        let upcoming = event(id: "upcoming", startsIn: 5 * 60, from: now)
        let dismissed = event(id: "dismissed", startsIn: 5 * 60, from: now)
        let result = MeetingMonitor.evaluate(
            events: [upcoming, dismissed],
            now: now,
            config: config(),
            activeRecording: false,
            dismissedEventIds: [dismissed.dedupeKey],
            remindedEventIds: [],
            countdownShownEventIds: []
        )
        XCTAssertEqual(extractIds(result), ["upcoming"])
    }
}

import Foundation

/// Pure-logic state machine that decides when calendar events deserve
/// attention. No EventKit, no UI, no timers — caller passes everything in.
///
/// Lives in `MacParakeetCore` so the coordinator (UI layer) and tests can
/// share the exact same evaluator. Keeping this `static` and `Sendable` makes
/// it trivially safe to call from any actor.
public enum MeetingMonitor {

    public enum MonitorEvent: Equatable, Sendable {
        /// Fires once per event in the window `[T - reminderMinutes, +90s]`.
        /// The 90-second forgiveness window catches slow polls — without it,
        /// a 60s timer that ticks 10s late would *miss* a reminder entirely.
        case reminderDue(CalendarEvent)

        /// Fires in the window `[T - 5s, T + 30s]` — gives the user a small
        /// late-grace tolerance for events that start a few seconds early.
        case autoStartDue(CalendarEvent)

        /// Fires in the window `(T + 30s, T + lateJoinGraceMinutes]`. Phase D
        /// keeps the case but does not wire UI — see ADR-017.
        case lateJoinAvailable(CalendarEvent)
    }

    public struct CalendarCandidate: Equatable, Sendable {
        public var event: CalendarEvent
        public var skipScope: CalendarSkipScope?

        public var isSkipped: Bool { skipScope != nil }

        public init(event: CalendarEvent, skipScope: CalendarSkipScope?) {
            self.event = event
            self.skipScope = skipScope
        }
    }

    public struct Config: Codable, Sendable, Equatable {
        public var mode: CalendarAutoStartMode
        /// 0 disables the reminder. Typical values: 1, 5, 10.
        public var reminderMinutes: Int
        /// Phase 2 — countdown duration before auto-start fires. Held here so
        /// the future coordinator wiring doesn't need a separate config type.
        public var countdownSeconds: Int
        public var triggerFilter: MeetingTriggerFilter
        public var lateJoinGraceMinutes: Int
        public var excludedCalendarIdentifiers: Set<String>
        public var skippedOccurrences: Set<String>
        public var skippedEvents: Set<String>

        public init(
            mode: CalendarAutoStartMode = .notify,
            reminderMinutes: Int = 5,
            countdownSeconds: Int = 5,
            triggerFilter: MeetingTriggerFilter = .withLink,
            lateJoinGraceMinutes: Int = 10,
            excludedCalendarIdentifiers: Set<String> = [],
            skippedOccurrences: Set<String> = [],
            skippedEvents: Set<String> = []
        ) {
            self.mode = mode
            self.reminderMinutes = reminderMinutes
            self.countdownSeconds = countdownSeconds
            self.triggerFilter = triggerFilter
            self.lateJoinGraceMinutes = lateJoinGraceMinutes
            self.excludedCalendarIdentifiers = excludedCalendarIdentifiers
            self.skippedOccurrences = skippedOccurrences
            self.skippedEvents = skippedEvents
        }

        public static let `default` = Config()
    }

    /// Shared candidate filter for Upcoming and the coordinator. Skipped
    /// events stay in the list and are annotated. Fail open when
    /// `calendarIdentifier` is missing.
    public static func candidates(
        events: [CalendarEvent],
        config: Config
    ) -> [CalendarCandidate] {
        events.compactMap { event in
            guard !event.isAllDay else { return nil }
            guard event.userStatus != .declined else { return nil }
            if let identifier = event.calendarIdentifier,
               config.excludedCalendarIdentifiers.contains(identifier)
            {
                return nil
            }
            guard passesTriggerFilter(event, filter: config.triggerFilter) else { return nil }
            let skipScope = CalendarSkip.matches(
                event,
                occurrences: config.skippedOccurrences,
                events: config.skippedEvents
            )
            return CalendarCandidate(event: event, skipScope: skipScope)
        }
    }

    /// Evaluate candidates and return any pending monitor events.
    /// Pure function — all state passed in, no side effects.
    ///
    /// The two suppression sets hold `CalendarEvent.dedupeKey` values (id +
    /// start time), not bare ids — so a rescheduled occurrence re-fires.
    public static func evaluate(
        candidates: [CalendarCandidate],
        now: Date,
        config: Config,
        activeRecording: Bool,
        remindedEventIds: Set<String>,
        countdownShownEventIds: Set<String>
    ) -> [MonitorEvent] {
        guard config.mode != .off else { return [] }

        var result: [MonitorEvent] = []

        for candidate in candidates {
            guard !candidate.isSkipped else { continue }
            let event = candidate.event

            if config.reminderMinutes > 0 && !remindedEventIds.contains(event.dedupeKey) {
                let reminderTime = event.startTime.addingTimeInterval(-Double(config.reminderMinutes * 60))
                let reminderWindowEnd = reminderTime.addingTimeInterval(90)
                if now >= reminderTime && now <= reminderWindowEnd {
                    result.append(.reminderDue(event))
                }
            }

            // Auto-start and late-join only fire when mode allows it AND we're
            // not already recording. They are *also* gated on RSVP: we don't
            // auto-record an invite the user declined or hasn't accepted
            // (`.pending`). Reminders stay lenient (declined-only) since a
            // notification is low-cost, but auto-recording a meeting you might
            // not attend is a surprise.
            if config.mode == .autoStart && !activeRecording
                && !countdownShownEventIds.contains(event.dedupeKey)
                && shouldAutoStart(forStatus: event.userStatus) {
                let autoStartBegin = event.startTime.addingTimeInterval(-5)
                let autoStartEnd = event.startTime.addingTimeInterval(30)
                if now >= autoStartBegin && now <= autoStartEnd {
                    result.append(.autoStartDue(event))
                }

                let lateJoinBegin = event.startTime.addingTimeInterval(30)
                let lateJoinEnd = event.startTime.addingTimeInterval(Double(config.lateJoinGraceMinutes * 60))
                if now > lateJoinBegin && now <= lateJoinEnd {
                    result.append(.lateJoinAvailable(event))
                }
            }
        }

        return result
    }

    public static func evaluate(
        events: [CalendarEvent],
        now: Date,
        config: Config,
        activeRecording: Bool,
        remindedEventIds: Set<String>,
        countdownShownEventIds: Set<String>
    ) -> [MonitorEvent] {
        evaluate(
            candidates: candidates(events: events, config: config),
            now: now,
            config: config,
            activeRecording: activeRecording,
            remindedEventIds: remindedEventIds,
            countdownShownEventIds: countdownShownEventIds
        )
    }

    /// Whether an event is eligible for *auto-start* (and late-join) based on
    /// the user's RSVP. `.declined` is already filtered out of candidates;
    /// this additionally blocks `.pending` (invited, not yet accepted). Own
    /// meetings and personal blocks surface as `.unknown`/`nil` and remain
    /// eligible.
    private static func shouldAutoStart(forStatus status: EventParticipant.ParticipantStatus?) -> Bool {
        switch status {
        case .declined, .pending:
            return false
        case .accepted, .tentative, .unknown, .none:
            return true
        }
    }

    public static func passesTriggerFilter(_ event: CalendarEvent, filter: MeetingTriggerFilter) -> Bool {
        switch filter {
        case .allEvents:
            return true
        case .withParticipants:
            return event.participants.count >= 1
        case .withLink:
            return event.meetUrl != nil
        }
    }
}

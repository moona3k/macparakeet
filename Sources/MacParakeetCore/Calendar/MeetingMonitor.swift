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

        /// Fires in the window `[endTime - autoStopLeadSeconds,
        /// endTime + autoStopForgiveness]`. Only emitted when
        /// `activeRecording == true`. The forgiveness tail past `endTime`
        /// catches a window missed during sleep or for a meeting that ran
        /// long — without it, the event drops out of the forward fetch the
        /// instant `now` passes `endTime` and the recording never auto-stops.
        case autoStopDue(CalendarEvent)
    }

    public struct Config: Codable, Sendable, Equatable {
        public var mode: CalendarAutoStartMode
        /// 0 disables the reminder. Typical values: 1, 5, 10.
        public var reminderMinutes: Int
        /// Phase 2 — countdown duration before auto-start fires. Held here so
        /// the future coordinator wiring doesn't need a separate config type.
        public var countdownSeconds: Int
        public var autoStopEnabled: Bool
        public var autoStopLeadSeconds: Int
        public var triggerFilter: MeetingTriggerFilter
        public var lateJoinGraceMinutes: Int

        public init(
            mode: CalendarAutoStartMode = .notify,
            reminderMinutes: Int = 5,
            countdownSeconds: Int = 5,
            autoStopEnabled: Bool = true,
            autoStopLeadSeconds: Int = 30,
            triggerFilter: MeetingTriggerFilter = .withLink,
            lateJoinGraceMinutes: Int = 10
        ) {
            self.mode = mode
            self.reminderMinutes = reminderMinutes
            self.countdownSeconds = countdownSeconds
            self.autoStopEnabled = autoStopEnabled
            self.autoStopLeadSeconds = autoStopLeadSeconds
            self.triggerFilter = triggerFilter
            self.lateJoinGraceMinutes = lateJoinGraceMinutes
        }

        public static let `default` = Config()
    }

    /// Evaluate calendar events and return any pending monitor events.
    /// Pure function — all state passed in, no side effects.
    ///
    /// The three suppression sets hold `CalendarEvent.dedupeKey` values (id +
    /// start time), not bare ids — so a rescheduled occurrence re-fires.
    public static func evaluate(
        events: [CalendarEvent],
        now: Date,
        config: Config,
        activeRecording: Bool,
        dismissedEventIds: Set<String>,
        remindedEventIds: Set<String>,
        countdownShownEventIds: Set<String>
    ) -> [MonitorEvent] {
        guard config.mode != .off else { return [] }

        let candidates = events.filter { event in
            guard !event.isAllDay else { return false }
            guard event.userStatus != .declined else { return false }
            guard !dismissedEventIds.contains(event.dedupeKey) else { return false }
            return passesFilter(event, filter: config.triggerFilter)
        }

        var result: [MonitorEvent] = []

        for event in candidates {
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

            if config.mode == .autoStart && config.autoStopEnabled && activeRecording {
                let autoStopBegin = event.endTime.addingTimeInterval(-Double(config.autoStopLeadSeconds))
                let autoStopEnd = event.endTime.addingTimeInterval(autoStopForgiveness)
                if now >= autoStopBegin && now <= autoStopEnd {
                    result.append(.autoStopDue(event))
                }
            }
        }

        return result
    }

    /// How long past an event's `endTime` the auto-stop window stays open.
    /// Lets a poll that lands late (resumed from sleep, or a meeting that ran
    /// long) still surface the auto-stop countdown rather than silently
    /// leaving the recording running. Beyond this the recording is left for a
    /// manual stop — we don't force-stop a recording for a meeting that ended
    /// long ago.
    ///
    /// Public so the coordinator's adaptive-polling logic can mirror this
    /// exact window: it polls fast through the forgiveness tail (when the
    /// event has dropped out of the forward fetch and the normal cadence
    /// math goes blind) and relaxes once the tail closes.
    public static let autoStopForgiveness: TimeInterval = 5 * 60

    /// Whether an event is eligible for *auto-start* (and late-join) based on
    /// the user's RSVP. `.declined` is already filtered out of candidates;
    /// this additionally blocks `.pending` (invited, not yet accepted). Own
    /// meetings and personal blocks surface as `.unknown`/`nil` and remain
    /// eligible. Auto-*stop* is intentionally NOT gated by this — once we're
    /// recording an event we still want to stop at its end regardless of RSVP.
    private static func shouldAutoStart(forStatus status: EventParticipant.ParticipantStatus?) -> Bool {
        switch status {
        case .declined, .pending:
            return false
        case .accepted, .tentative, .unknown, .none:
            return true
        }
    }

    private static func passesFilter(_ event: CalendarEvent, filter: MeetingTriggerFilter) -> Bool {
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

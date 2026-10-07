import Foundation
import MacParakeetCore

/// A one-time banner for a combined meeting that keeps recording while one
/// selected source is missing. Calendar auto-start opens no panel, so without
/// it the user learns about a missing side only after the meeting (#1223).
public struct MeetingSourceLossNotice: Equatable, Sendable {
    public let source: MeetingSourceHealth.Source
    public let title: String
    public let body: String

    static func make(source: MeetingSourceHealth.Source, status: MeetingSourceHealth.Status) -> Self {
        switch (source, status) {
        case (.microphone, .unavailable):
            return Self(
                source: source,
                title: "This meeting may be missing your side",
                body:
                    "Your microphone isn't being recorded. MacParakeet is still saving system audio and will add your microphone if it reconnects."
            )
        case (.microphone, _):
            return Self(
                source: source,
                title: "This meeting may be missing your side",
                body:
                    "Your microphone stopped recording. MacParakeet is still saving system audio. Check your input device, or stop and start a new recording."
            )
        case (.system, _):
            return Self(
                source: source,
                title: "This meeting may be missing other participants",
                body: "System audio isn't being recorded. MacParakeet is still saving your microphone."
            )
        }
    }
}

/// Decides when a live meeting deserves a source-loss banner. A selected
/// source must stay unavailable or interrupted for `threshold` seconds of
/// active recording, so brief startup or route-change gaps stay quiet. The
/// visible live panel already shows the warning, so the banner waits while it
/// is open. At most one banner per recording.
public struct MeetingSourceLossNoticePolicy: Sendable {
    public static let defaultThreshold: TimeInterval = 10

    private let threshold: TimeInterval
    private var lostSince: [MeetingSourceHealth.Source: Date] = [:]
    private var hasNotified = false

    public init(threshold: TimeInterval = Self.defaultThreshold) {
        self.threshold = threshold
    }

    public mutating func reset() {
        lostSince = [:]
        hasNotified = false
    }

    public mutating func evaluate(
        health: MeetingCaptureHealthSummary,
        isActivelyRecording: Bool,
        isPanelVisible: Bool,
        now: Date
    ) -> MeetingSourceLossNotice? {
        guard !hasNotified else { return nil }
        // When the only selected source fails, capture itself stops.
        guard health.sourceMode == .microphoneAndSystem else {
            lostSince = [:]
            return nil
        }

        var notice: MeetingSourceLossNotice?
        for sourceHealth in [health.microphone, health.system] {
            let source = sourceHealth.source
            guard isActivelyRecording, Self.isLost(sourceHealth.status) else {
                lostSince[source] = nil
                continue
            }
            let since = lostSince[source] ?? now
            lostSince[source] = since
            if notice == nil, now.timeIntervalSince(since) >= threshold {
                notice = .make(source: source, status: sourceHealth.status)
            }
        }

        guard let notice, !isPanelVisible else { return nil }
        hasNotified = true
        return notice
    }

    private static func isLost(_ status: MeetingSourceHealth.Status) -> Bool {
        status == .unavailable || status == .interrupted
    }
}

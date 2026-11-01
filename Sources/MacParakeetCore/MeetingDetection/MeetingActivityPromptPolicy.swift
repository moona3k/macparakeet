import Foundation

/// Stateful prompt policy with no I/O. A call ends only after its identifying
/// signals have stayed absent for `sessionEndGrace`, so mute/reconnect does not
/// cause repeat prompts. Different browser rooms have independent lifetimes.
public struct MeetingActivityPromptPolicy: Sendable {
    private struct Session: Sendable {
        let candidate: MeetingPromptCandidate
        var firstSeen: Date
        var absentSince: Date?
        var prompted = false
    }

    public let candidateDwellSeconds: TimeInterval
    public let sessionEndGrace: TimeInterval
    public private(set) var currentPrompt: MeetingPromptCandidate?
    private var sessions: [String: Session] = [:]
    private var activeCandidates: [String: MeetingPromptCandidate] = [:]
    private var continuityBrowserBundleIDs: Set<String> = []

    public init(candidateDwellSeconds: TimeInterval = 3, sessionEndGrace: TimeInterval = 30) {
        self.candidateDwellSeconds = max(0, candidateDwellSeconds)
        self.sessionEndGrace = max(0, sessionEndGrace)
    }

    /// The driver only needs a timer while a dwell or end grace is pending.
    /// Stable, already-prompted calls require only activity-change callbacks.
    public var needsRefresh: Bool {
        sessions.contains { id, session in
            if !session.prompted { return true }
            let preserved =
                session.candidate.app == .browser
                && continuityBrowserBundleIDs.contains(session.candidate.bundleID)
            return activeCandidates[id] == nil && !preserved
        }
    }

    public func activeCandidate(id: String) -> MeetingPromptCandidate? {
        activeCandidates[id]
    }

    public mutating func dismiss(id: String) {
        sessions[id]?.prompted = true
        if currentPrompt?.id == id { currentPrompt = nil }
    }

    /// Called once when capture actually begins, never for permission checks or
    /// failed starts. An activity-confirmed recording has a known candidate; a
    /// manual/calendar start can only be attributed when one candidate is known.
    /// Ambiguous concurrent calls remain eligible rather than all being consumed.
    public mutating func recordingDidBegin(candidateID: String? = nil) {
        let recordedID = candidateID ?? (activeCandidates.count == 1 ? activeCandidates.keys.first : nil)
        guard let recordedID else { return }
        dismiss(id: recordedID)
    }

    /// Explicit room-end/pre-join observations override uncertain continuity.
    /// Clearing the active observation also invalidates any stale button.
    public mutating func resetSessions(for ids: Set<String>) {
        for id in ids {
            sessions[id] = nil
            activeCandidates[id] = nil
        }
        if let currentPrompt, ids.contains(currentPrompt.id) { self.currentPrompt = nil }
    }

    public mutating func update(
        candidates: [MeetingPromptCandidate],
        now: Date,
        canPrompt: Bool,
        isRecording: Bool,
        preservedBrowserBundleIDs: Set<String> = []
    ) -> MeetingPromptCandidate? {
        let incoming = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        continuityBrowserBundleIDs = preservedBrowserBundleIDs
        // Expire absent sessions before refreshing returning candidates. This
        // recognizes a new call even when the driver did not tick during idle.
        sessions = sessions.filter { _, session in
            guard let absentSince = session.absentSince else { return true }
            // An inactive/background tab may stop exposing AX call controls
            // while its browser remains running. Keep only the suppression;
            // active candidates and prompt actions always need fresh evidence.
            if session.prompted, session.candidate.app == .browser,
                preservedBrowserBundleIDs.contains(session.candidate.bundleID)
            {
                return true
            }
            return now.timeIntervalSince(absentSince) < sessionEndGrace
        }
        activeCandidates = incoming
        for id in Array(sessions.keys) where incoming[id] == nil {
            if sessions[id]?.absentSince == nil { sessions[id]?.absentSince = now }
        }
        for candidate in candidates {
            var session = sessions[candidate.id] ?? Session(candidate: candidate, firstSeen: now)
            // Short unrelated mic blips must not accumulate into a completed
            // dwell. Only already-observed sessions retain their suppression.
            if session.absentSince != nil, !session.prompted { session.firstSeen = now }
            session.absentSince = nil
            sessions[candidate.id] = session
        }
        if let currentPrompt {
            // A missed AX/mic observation invalidates Record immediately via
            // activeCandidates, but preserves the dismissible offer through the
            // end grace. Returning evidence restores its Record action.
            guard let session = sessions[currentPrompt.id] else {
                self.currentPrompt = nil
                return nextPrompt(candidates: incoming, now: now, canPrompt: canPrompt, isRecording: isRecording)
            }
            if let absentSince = session.absentSince,
                now.timeIntervalSince(absentSince) >= sessionEndGrace
            {
                self.currentPrompt = nil
            }
        }
        return nextPrompt(candidates: incoming, now: now, canPrompt: canPrompt, isRecording: isRecording)
    }

    private mutating func nextPrompt(
        candidates incoming: [String: MeetingPromptCandidate], now: Date, canPrompt: Bool, isRecording: Bool
    ) -> MeetingPromptCandidate? {
        guard canPrompt, !isRecording, currentPrompt == nil else { return nil }
        for candidate in incoming.values.sorted(by: { $0.id < $1.id }) {
            guard var session = sessions[candidate.id], !session.prompted,
                now.timeIntervalSince(session.firstSeen) >= candidateDwellSeconds
            else { continue }
            session.prompted = true
            sessions[candidate.id] = session
            currentPrompt = candidate
            return candidate
        }
        return nil
    }
}
